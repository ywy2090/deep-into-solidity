# CCIP Gas 机制深度解析

> 本文档覆盖 Chainlink CCIP 协议中所有与 Gas 相关的设计：**源链费用计算** → **Gas 参数编码** → **目标链 Gas 限制执行** → **gasBuffer 保护** → **callWithExactGas 原语**。

---

## 目录

1. [概览：Gas 在 CCIP 中的角色](#1-概览gas-在-ccip-中的角色)
2. [ExtraArgs 中的 gasLimit 参数](#2-extraargs-中的-gaslimit-参数)
3. [源链费用计算：FeeQuoter 与 OnRamp](#3-源链费用计算feeQuoter-与-onramp)
   - 3.1 [Gas 计费公式](#31-gas-计费公式)
   - 3.2 [_getReceipts：各组件 Gas 汇总](#32-_getreceipts各组件-gas-汇总)
   - 3.3 [quoteGasForExec：最终总 Gas 和费用](#33-quotegasforexec最终总-gas-和费用)
4. [目标链 Gas 执行：OffRamp](#4-目标链-gas-执行offramp)
   - 4.1 [gasLimitOverride：执行者覆盖机制](#41-gaslimitoverride执行者覆盖机制)
   - 4.2 [_callWithGasBuffer：防 OOG 保护](#42-_callwithgasbuffer防-oog-保护)
   - 4.3 [callWithExactGas：精确 Gas 传递](#43-callwithexactgas精确-gas-传递)
5. [token-only 转账的 Gas 优化](#5-token-only-转账的-gas-优化)
6. [Gas 相关的错误与防御](#6-gas-相关的错误与防御)
7. [Gas 参数完整流转图](#7-gas-参数完整流转图)
8. [常见问题 FAQ](#8-常见问题-faq)

---

## 1. 概览：Gas 在 CCIP 中的角色

CCIP 消息跨链时涉及**两条链**上的 Gas：

| 链 | Gas 的用途 |
|---|---|
| **源链** | 用户在源链发送消息时**预付**目标链执行费用，以 feeToken（如 LINK、ETH）计价 |
| **目标链** | Executor（执行者）用提前收取的费用在目标链提交 `OffRamp.execute()`，完成消息交付 |

Gas 的核心设计目标：
- **用户无需在目标链持有 gas token**：所有目标链 Gas 由用户在源链预付给 CCIP 协议。
- **有限 Gas 隔离**：目标链执行使用 `callWithExactGas` 以用户指定的精确 Gas 调用 `ccipReceive`，防止 receiver 恶意消耗所有 Gas。
- **Gas 不足保护**：`_callWithGasBuffer` 保留足够 Gas 用于状态更新，即使 receiver 执行 OOG 也能写入 `FAILURE` 状态。

---

## 2. ExtraArgs 中的 gasLimit 参数

用户发送消息时通过 `extraArgs` 字段指定目标链 Gas 限制，编码格式定义在 `ExtraArgsCodec.sol`。

### 结构定义

```solidity
// chains/evm/contracts/libraries/ExtraArgsCodec.sol

struct GenericExtraArgsV3 {
  /// @dev 目标链 ccipReceive 回调的 Gas 上限。
  /// gasLimit=0 且 data 为空 => 跳过 ccipReceive（纯代币转账）。
  /// 发送方按此 gasLimit 计费，未使用的 Gas 不退款。
  uint32 gasLimit;

  /// @notice 等待的区块确认数。0 = 使用 CCV 默认最终性。
  uint16 blockConfirmations;

  address[] ccvs;      // 用户指定的 CCVs（为空则使用链级默认）
  bytes[]   ccvArgs;   // 每个 CCV 的参数
  address   executor;  // 指定 executor（为空则使用默认）
  bytes     executorArgs; // executor 目标链参数（SVM/SUI 账户列表）
  bytes     tokenReceiver; // 代币接收地址（为空则用 message.receiver）
  bytes     tokenArgs;    // TokenPool 参数
}
```

### 编码格式（ExtraArgsV3 二进制布局）

```
tag(4) + gasLimit(4) + blockConfirmations(2) + ccvsLength(1) + ...变长字段
```

`GENERIC_EXTRA_ARGS_V3_TAG = 0xa69dd4aa`

### 快捷构造函数

```solidity
// 仅设置 gasLimit + blockConfirmations 的最简 extraArgs
function _getBasicEncodedExtraArgsV3(
  uint32 gasLimit,
  uint16 blockConfirmations
) internal pure returns (bytes memory) {
  return abi.encodePacked(GENERIC_EXTRA_ARGS_V3_TAG, gasLimit, blockConfirmations, bytes7(0));
}
```

### gasLimit 含义要点

| 场景 | gasLimit 建议值 |
|---|---|
| 仅代币转账（无回调） | `0`（配合空 data） |
| 有 `ccipReceive` 回调 | 足够执行回调逻辑（需用户估算） |
| EOA 接收者 | 任意值（OffRamp 跳过 ccipReceive） |

> **重要**：用户按 `gasLimit` 计费，不是实际用量。未消耗的 Gas 不退款。

---

## 3. 源链费用计算：FeeQuoter 与 OnRamp

### 3.1 Gas 计费公式

`FeeQuoter.getValidatedFee()`（Legacy 路径）使用如下公式：

```
总目标链 Gas = destGasOverhead            // 固定协议 overhead（commit + exec 基础成本）
             + tokenTransferGas            // 代币转账 gas（来自 pool 或 FeeQuoter 配置）
             + destCallDataCost            // calldata 费用 = (data.length + extraArgs.length + tokenBytes) * destGasPerPayloadByteBase
             + gasLimit                    // 用户指定的 ccipReceive Gas
```

对应代码（`FeeQuoter.sol:739`）：
```solidity
uint256 totalDestChainGas = destChainConfig.destGasOverhead
  + tokenTransferGas
  + destCallDataCost
  + gasLimit;
```

最终费用（以 feeToken 计价）：
```
fee = (totalDestChainGas × gasPrice × 1e18 + premiumFeeUSDWei) / feeTokenPrice
```

### DestChainConfig 中的 Gas 配置项

| 字段 | 含义 |
|---|---|
| `maxPerMsgGasLimit` | 单条消息允许的最大 Gas（用户 gasLimit 上限） |
| `destGasOverhead` | LEGACY：每条消息固定的协议 Gas 开销 |
| `destGasPerPayloadByteBase` | 每字节 calldata 消耗的 Gas（含 DA 成本） |
| `defaultTxGasLimit` | extraArgs 缺省时使用的 Gas 限制 |
| `defaultTokenDestGasOverhead` | 无自定义配置时每个代币转账的默认 Gas |

### 3.2 _getReceipts：各组件 Gas 汇总

新版路径（v2 OnRamp）通过 `OnRamp._getReceipts()` 从各参与方收集 Gas 报价：

```
OnRamp._getReceipts()
  ├─ for each CCV → ICrossChainVerifierV1.getFee()    → gasForVerification（链上验证 Gas）
  ├─ TokenPool → IPoolV2.getFee() 或 FeeQuoter.getTokenTransferFee()
  │     → destGasLimit（链上释放/铸币 Gas）
  ├─ Executor → OnRamp._getExecutionFee()
  │     → destGasLimit = baseExecutionGasCost + extraArgs.gasLimit   ← 包含用户指定 Gas
  └─ Network fee（Flat fee，issuer = Router）
```

关键实现（`OnRamp.sol:1120-1128`）：
```solidity
// _getExecutionFee 中 executor 的 gas 成本
return Receipt({
  issuer: extraArgs.executor,
  destGasLimit: destChainConfig.baseExecutionGasCost + extraArgs.gasLimit,
  // ...
});
```

`gasLimitSum` 汇总了所有组件的 `destGasLimit`，最后传给 `FeeQuoter.quoteGasForExec()`。

### 3.3 quoteGasForExec：最终总 Gas 和费用

```solidity
// FeeQuoter.sol:301
function quoteGasForExec(
  uint64 destChainSelector,
  uint32 nonCalldataGas,   // gasLimitSum（来自 _getReceipts）
  uint32 calldataSize,     // bytesOverheadSum
  address feeToken
) external view returns (
  uint32  totalGas,              // 含 calldata gas 的最终总 Gas
  uint256 gasCostInUsdCents,
  uint256 feeTokenPrice,
  uint256 premiumPercentMultiplier
) {
  totalGas = nonCalldataGas + calldataSize * destChainConfig.destGasPerPayloadByteBase;

  if (totalGas > destChainConfig.maxPerMsgGasLimit) revert MessageGasLimitTooHigh();
  // ...
  gasCostInUsdCents = (totalGas * gasPrice + (1e16 - 1)) / 1e16; // 向上取整
}
```

这里 `totalGas > maxPerMsgGasLimit` 时会 revert，防止消息设置过高的 Gas。

---

## 4. 目标链 Gas 执行：OffRamp

### 4.1 gasLimitOverride：执行者覆盖机制

`OffRamp.execute()` 接受一个 `gasLimitOverride` 参数，允许执行者覆盖消息中原始的 `ccipReceiveGasLimit`：

```solidity
// OffRamp.sol:192
function execute(
  bytes calldata encodedMessage,
  address[] calldata ccvs,
  bytes[] calldata verifierResults,
  uint32 gasLimitOverride   // 0 = 不覆盖，使用 message.ccipReceiveGasLimit
) external {
  // ...
  // 非零覆盖不得低于消息原始 gasLimit（防止 DOS 低 Gas 攻击）
  if (gasLimitOverride != 0 && gasLimitOverride < message.ccipReceiveGasLimit) {
    revert InvalidGasLimitOverride(message.ccipReceiveGasLimit, gasLimitOverride);
  }
  // ...
}
```

`gasLimitOverride` 传递路径：
```
execute(gasLimitOverride)
  → _callWithGasBuffer(encodeSingleMessage(..., gasLimitOverride))
    → executeSingleMessage(..., gasLimitOverride)
      → _callReceiver(message, receiver, gasLimitOverride != 0 ? gasLimitOverride : message.ccipReceiveGasLimit)
        → router.routeMessage(message, gasForCallExactCheck, gasLimit, receiver)
```

### 4.2 _callWithGasBuffer：防 OOG 保护

`_callWithGasBuffer` 在调用 `executeSingleMessage` 时保留 `i_maxGasBufferToUpdateState` 的 Gas，确保即使 receiver 耗尽 Gas，OffRamp 仍能写入最终执行状态。

```solidity
// OffRamp.sol:268
function _callWithGasBuffer(
  bytes memory payload
) internal returns (bool success, bytes memory retData) {
  retData = new bytes(Internal.MAX_RET_BYTES);

  uint256 gasLeft = gasleft();
  if (gasLeft <= i_maxGasBufferToUpdateState) {
    revert InsufficientGasToCompleteTx(bytes4(uint32(gasleft())));
  }

  uint256 gasLimit = gasLeft - i_maxGasBufferToUpdateState; // ← 预留 buffer

  assembly {
    // call(gas, addr, value, argsOffset, argsLength, retOffset, retLength)
    success := call(gasLimit, address(), 0, add(payload, 0x20), mload(payload), 0x0, 0x0)
    // ... copy return data ...
  }
}
```

`i_maxGasBufferToUpdateState` 来自 `StaticConfig.maxGasBufferToUpdateState`（典型值约 10k-20k Gas），包含：
- 写入 `s_executionStates[messageId]` 的 Gas（约 5k）
- 触发 `ExecutionStateChanged` 事件的 Gas（约 5k）

### 4.3 callWithExactGas：精确 Gas 传递

Router 使用 `CallWithExactGas._callWithExactGasSafeReturnData()` 以精确 Gas 调用 receiver：

```solidity
// Router.sol:173
(success, retData, gasUsed) = CallWithExactGas._callWithExactGasSafeReturnData(
  data,                    // abi.encode(ccipReceive, message)
  receiver,
  gasLimit,                // gasLimitOverride 或 message.ccipReceiveGasLimit
  gasForCallExactCheck,    // i_gasForCallExactCheck（OffRamp 配置）
  Internal.MAX_RET_BYTES   // 返回数据最大长度（防 return bomb）
);
```

`gasForCallExactCheck` 的作用：EVM 中 `call` 传入的 Gas 经 63/64 规则截断，`gasForCallExactCheck` 用于验证实际传入的 Gas 不低于要求值，确保 "exact gas" 语义。

```
StaticConfig.gasForCallExactCheck → OffRamp.i_gasForCallExactCheck
  → OffRamp._callReceiver(... i_gasForCallExactCheck ...)
    → Router.routeMessage(... gasForCallExactCheck ...)
      → CallWithExactGas._callWithExactGasSafeReturnData(... gasForCallExactCheck ...)
```

---

## 5. token-only 转账的 Gas 优化

当消息为纯代币转账（无 `ccipReceive` 回调）时，OffRamp 通过 `_isTokenOnlyTransfer()` 检查跳过 `ccipReceive`，节省目标链 Gas：

```solidity
// OffRamp.sol:418-426
function _isTokenOnlyTransfer(
  uint256 dataLength,
  uint256 ccipReceiveGasLimit,
  address receiver
) internal view returns (bool) {
  return (dataLength == 0 && ccipReceiveGasLimit == 0)  // 空 data + 0 gasLimit
    || receiver.code.length == 0                         // EOA 接收者
    || !receiver._supportsInterfaceReverting(            // 不支持 ccipReceive 接口
        type(IAny2EVMMessageReceiver).interfaceId
      );
}
```

三种跳过 ccipReceive 的情形：

| 条件 | 说明 |
|---|---|
| `data == 空 && ccipReceiveGasLimit == 0` | 用户明确表示纯代币转账 |
| `receiver.code.length == 0`（EOA） | 目标是普通钱包地址，无法调用 |
| 不支持 `IAny2EVMMessageReceiver` 接口 | 合约未实现 ccipReceive |

此时 `ccipReceiveGasLimit` 仅影响计费，不影响执行路径——即使 gasLimit=0，代币转账照常完成。

> **注意**：源链计费时 gasLimit 仍被计入（若>0），但目标链不会为此消耗 Gas 调用 receiver。

---

## 6. Gas 相关的错误与防御

### OffRamp 错误

| 错误 | 触发条件 | 来源 |
|---|---|---|
| `InvalidGasLimitOverride(msgGas, overrideGas)` | `gasLimitOverride != 0 && gasLimitOverride < message.ccipReceiveGasLimit` | `OffRamp.execute` |
| `InsufficientGasToCompleteTx(gasLeft)` | 调用前 `gasleft() <= i_maxGasBufferToUpdateState` | `_callWithGasBuffer` |
| `GasCannotBeZero` | 构造时 `gasForCallExactCheck == 0` 或 `maxGasBufferToUpdateState == 0` | `OffRamp.constructor` |
| `ReceiverError(returnData)` | `ccipReceive` 回调 revert | `_callReceiver` |

### FeeQuoter 错误

| 错误 | 触发条件 |
|---|---|
| `MessageGasLimitTooHigh()` | `totalGas > maxPerMsgGasLimit` |
| `NoGasPriceAvailable(destChainSelector)` | 目标链无 Gas 价格数据 |

### 设计意图

- `InvalidGasLimitOverride`：防止 executor 故意用低 Gas 使消息 OOG，从而阻塞正常执行。
- `_callWithGasBuffer` + `NoStateProgressMade`：保证消息状态机最终收敛（要么 SUCCESS 要么 FAILURE），即使 receiver 实现有 Bug。
- `callWithExactGas`：隔离 receiver 与外部 Gas 环境，防止 receiver 通过 Gas 操纵影响 OffRamp 控制流。

---

## 7. Gas 参数完整流转图

```
用户调用 Router.ccipSend(destChainSelector, message)
│
│  message.extraArgs 中包含：gasLimit（用户指定的 ccipReceive Gas）
│
├─ OnRamp.forwardFromRouter()
│    ├─ resolvedExtraArgs.gasLimit = ExtraArgsCodec.parse(message.extraArgs).gasLimit
│    │    └─ 若 extraArgs 为空 → 使用 FeeQuoter.defaultTxGasLimit
│    │
│    ├─ newMessage.ccipReceiveGasLimit = resolvedExtraArgs.gasLimit    ← 写入链上消息
│    │
│    └─ _getReceipts(...)
│         ├─ CCV.getFee()      → gasForVerification（验证 Gas）
│         ├─ Pool.getFee()     → tokenDestGasLimit（代币释放 Gas）
│         ├─ _getExecutionFee()→ baseExecutionGasCost + gasLimit      ← executor gas
│         └─ FeeQuoter.quoteGasForExec(gasLimitSum, bytesOverheadSum)
│              └─ totalGas = gasLimitSum + calldata_bytes × perByteCost
│                 检查 totalGas ≤ maxPerMsgGasLimit
│                 → 返回 gasCostInUsdCents + feeTokenPrice
│
│  [Off-Chain] Execute Plugin 读取 CommitReport，获取完整消息
│
└─ OffRamp.execute(encodedMessage, ccvs, verifierResults, gasLimitOverride)
     │
     ├─ 验证 gasLimitOverride ≥ message.ccipReceiveGasLimit（若非 0）
     │
     ├─ _callWithGasBuffer(executeSingleMessage payload)
     │    ├─ 检查 gasleft() > maxGasBufferToUpdateState
     │    └─ 以 gasLeft - maxGasBufferToUpdateState 调用 executeSingleMessage
     │
     └─ executeSingleMessage(..., gasLimitOverride)
          ├─ _isTokenOnlyTransfer() → true 则跳过 ccipReceive
          │
          └─ _callReceiver(message, receiver,
               gasLimitOverride != 0 ? gasLimitOverride : message.ccipReceiveGasLimit)
               │
               └─ Router.routeMessage(message, gasForCallExactCheck, gasLimit, receiver)
                    └─ CallWithExactGas._callWithExactGasSafeReturnData(
                         data, receiver, gasLimit, gasForCallExactCheck, MAX_RET_BYTES)
                         └─ 以精确 gasLimit 调用 receiver.ccipReceive(message)
```

---

## 8. 常见问题 FAQ

**Q：用户设置的 gasLimit 和实际消耗 Gas 不一样，会退款吗？**
> 不会。用户按 `extraArgs.gasLimit` 计费，多余 Gas 不退还。建议使用合理估算值，略高于预期消耗。

**Q：gasLimitOverride 是谁设置的？**
> Executor（执行者）在调用 `OffRamp.execute()` 时设置。通常 Executor 在消息第一次执行失败（`FAILURE`）后可以用更高的 gas 重试（提高 `gasLimitOverride`），但不能低于 `message.ccipReceiveGasLimit`。

**Q：如果目标链 Gas 价格飙升，消息会失败吗？**
> 源链已预付 Gas 费用，目标链执行时 Executor 使用预付费用按需支付。Gas 价格波动由 Executor 和 CCIP 协议吸收，一般不影响消息最终交付。

**Q：ccipReceive 执行 OOG（Out of Gas）会怎样？**
> `_callWithGasBuffer` 捕获 OOG，将消息状态写为 `FAILURE`，而非整个交易 revert。消息可在之后用更高 gasLimitOverride 重试。

**Q：gasForCallExactCheck 是什么？为什么需要它？**
> EVM 的 `call` 遵循 63/64 规则（只能传入当前 Gas 的 63/64），`gasForCallExactCheck` 是 `CallWithExactGas` 库的最小检验值，确保传入 receiver 的 Gas 不低于用户要求，维护 "exact gas" 语义的安全性。

**Q：maxGasBufferToUpdateState 的典型值是多少？**
> 构造函数要求非零，协议典型配置约 10,000–20,000 Gas（5k 写状态 + 5k 发事件）。可通过读取 `OffRamp.getStaticConfig().maxGasBufferToUpdateState` 查询链上配置。
