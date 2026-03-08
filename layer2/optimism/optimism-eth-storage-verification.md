# L1 桥接 ETH 存储位置 — 源码验证

本文从源码追踪 L1→L2 存款与 L2→L1 提款时的 ETH 流向，验证相关注释是否正确。

## 适用前提

- 本文讨论的是 **native ETH 模式** 下的桥接路径。若系统启用了 `CUSTOM_GAS_TOKEN`，则原生 ETH 的存款与提款会被 `OptimismPortal` 禁止。
- 文中“启用 `ETH_LOCKBOX`”的准确含义是：`systemConfig` 打开 `ETH_LOCKBOX` feature，且 `OptimismPortal` 已配置非零的 `ethLockbox` 地址。
- 本文重点分析的是 **经 `L1StandardBridge` / `L2StandardBridge` 的标准桥 ETH 路径**；若用户直接调用 `OptimismPortal.depositTransaction(...)`，其 L2 执行路径与标准桥消息路径不同。

## 源码引用

基于 [ethereum-optimism/optimism](https://github.com/ethereum-optimism/optimism) @ [`b053ac1`](https://github.com/ethereum-optimism/optimism/commit/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b)：

| 合约 / 文件 | 路径 | 链接 |
| ----------- | ---- | ---- |
| StandardBridge | `packages/contracts-bedrock/src/universal/StandardBridge.sol` | [源码](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/universal/StandardBridge.sol) |
| L1StandardBridge | `packages/contracts-bedrock/src/L1/L1StandardBridge.sol` | [源码](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/L1StandardBridge.sol) |
| L1CrossDomainMessenger | `packages/contracts-bedrock/src/L1/L1CrossDomainMessenger.sol` | [源码](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/L1CrossDomainMessenger.sol) |
| OptimismPortal2 | `packages/contracts-bedrock/src/L1/OptimismPortal2.sol` | [源码](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/OptimismPortal2.sol) |
| ETHLockbox | `packages/contracts-bedrock/src/L1/ETHLockbox.sol` | [源码](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/ETHLockbox.sol) |
| L2CrossDomainMessenger | `packages/contracts-bedrock/src/L2/L2CrossDomainMessenger.sol` | [源码](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L2/L2CrossDomainMessenger.sol) |
| L2ToL1MessagePasser | `packages/contracts-bedrock/src/L2/L2ToL1MessagePasser.sol` | [源码](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L2/L2ToL1MessagePasser.sol) |
| Features | `packages/contracts-bedrock/src/libraries/Features.sol` | [源码](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/libraries/Features.sol) |

## 目录

- [1. 路径总览](#1-路径总览)
  - [1.1 L1 到 L2：存款路径](#11-l1-到-l2存款路径)
  - [1.2 L2 到 L1：提款路径](#12-l2-到-l1提款路径)
  - [1.3 路径示意](#13-路径示意)
- [2. L1 到 L2：存款路径](#2-l1-到-l2存款路径)
  - [2.1 存款路径](#21-存款路径)
  - [2.2 失败与重放](#22-失败与重放)
- [3. L2 到 L1：提款路径](#3-l2-到-l1提款路径)
  - [3.1 取款路径](#31-取款路径)
  - [3.2 失败与重放](#32-失败与重放)
- [4. 小结](#4-小结)
- [附录 A. CUSTOM_GAS_TOKEN 模式补充说明](#附录-a-custom_gas_token-模式补充说明)

---

## 1. 路径总览

### 1.1 L1 到 L2：存款路径

同一笔交易内，ETH 按以下顺序「流经」各合约（每步通过 `msg.value` 或 `{ value }` 传递，中间合约不沉淀）：

| 步骤 | ETH 所在位置 | 触发动作 |
| ---- | ------------ | -------- |
| 0 | 用户钱包 | 用户发送交易并附带 `value` |
| 1 | **L1StandardBridge** | 用户调用 `receive()` / `depositETH()` / `depositETHTo()`，ETH 作为 `msg.value` 进入 Bridge |
| 2 | **L1CrossDomainMessenger** | Bridge 调用 `messenger.sendMessage{ value: _amount }()`，ETH 转入 Messenger |
| 3a | **OptimismPortal** | Messenger 调用 `portal.depositTransaction{ value: _value }()`，ETH 转入 Portal（未启用 Lockbox） |
| 3b | **ETHLockbox** | 若启用 Lockbox，Portal 在 `depositTransaction` 内调用 `ethLockbox.lockETH{ value: msg.value }()`，ETH 从 Portal 转入 Lockbox |
| — | L2 侧 | op-node 监听 `TransactionDeposited` 事件，在 L2 派生存款交易，用户在 L2 收到等额 ETH（铸造） |

#### L2 侧（对侧链）存款路径：标准桥 ETH 的真实执行链

| 步骤 | ETH 所在位置（L2） | 说明 |
| ---- | ------------------ | ---- |
| 0 | **L2CrossDomainMessenger** | L1 侧 `sendMessage` 最终会通过 `OptimismPortal.depositTransaction` 发出一笔以 `L2CrossDomainMessenger.relayMessage(...)` 为目标的存款交易。这笔交易在 L2 上执行时，`msg.value` 会先进入 `L2CrossDomainMessenger` |
| 1 | **L2StandardBridge** | `L2CrossDomainMessenger.relayMessage(...)` 调用 `L2StandardBridge.finalizeBridgeETH(...)`，并将同一笔 `value` 转给 `L2StandardBridge` |
| 2 | **接收者 L2 地址余额** | `L2StandardBridge.finalizeBridgeETH(...)` 再把 ETH 转给最终接收者 `_to`。成功时 ETH 最终到达接收者；若消息或桥接调用失败，ETH 通常暂留在 `L2CrossDomainMessenger`，等待后续重放 |

#### 存款路径小结

- **L1**（未启用 ETH_LOCKBOX）：`用户 → L1StandardBridge → L1CrossDomainMessenger → OptimismPortal`（**最终沉淀在 Portal**）。
- **L1**（启用 ETH_LOCKBOX）：`用户 → L1StandardBridge → L1CrossDomainMessenger → OptimismPortal → ETHLockbox`（**最终沉淀在 ETHLockbox**）。
- **L2**：标准桥路径下为 `L2CrossDomainMessenger → L2StandardBridge → 接收者 L2 地址`；成功时最终到账，失败时 ETH 通常暂留在 `L2CrossDomainMessenger` 并等待重放。

### 1.2 L2 到 L1：提款路径

提款分两阶段：**L2 侧提款发起**（扣减 L2 余额并记录提款）与 **L1 侧提款最终确认**（在 L1 支付 ETH）。

#### L2 侧提款发起路径

| 步骤 | ETH 所在位置（L2） | 触发动作 |
| ---- | ------------------ | -------- |
| 0 | **用户 L2 地址** | 用户调用 L2StandardBridge 的 `bridgeETHTo` / `withdraw` 或 L2CrossDomainMessenger 的 `sendMessage`，并附带 `value` |
| 1 | **L2CrossDomainMessenger** | Bridge 调用 `messenger.sendMessage{ value: _amount }()`，ETH 作为 `msg.value` 进入 Messenger |
| 2 | **L2ToL1MessagePasser** | Messenger 调用 `L2ToL1MessagePasser.initiateWithdrawal{ value: _value }()`，ETH 转入该预部署合约余额；合约将提款哈希写入 `sentMessages`，发出 `MessagePassed` 事件 |
| 3 | **L2ToL1MessagePasser（沉淀）** | 合约持有 ETH，后续可由任何人调用 `burn()` 销毁其**当前余额**。`burn()` 是批量销毁语义，不是“每笔提款逐笔一一销毁”，但总体作用仍是使 L2 侧 ETH 供应与 L1 释放保持一致 |

#### L1 侧最终确认路径

| 步骤 | ETH 所在位置（L1） | 触发动作 |
| ---- | ------------------ | -------- |
| 0 | **OptimismPortal** 或 **ETHLockbox** | 存款阶段沉淀的 ETH（见 1.1） |
| 1 | **OptimismPortal** | 若启用 Lockbox：Portal 调用 `ethLockbox.unlockETH(_tx.value)`，Lockbox 通过 `portal.donateETH{ value: _value }()` 将 ETH 打回 Portal |
| 2 | **L1StandardBridge** | Portal 调用 `SafeCall.callWithMinGas(_tx.target, ..., _tx.value, _tx.data)`，`_tx.target` 为 Bridge，ETH 作为 `msg.value` 进入 Bridge |
| 3 | **用户 L1 地址** | Bridge 在 `finalizeBridgeETH` 内执行 `SafeCall.call(_to, ..., _amount, "")`，ETH 转给提款接收者 `_to` |

#### 提款路径小结

- **L2**：`用户 L2 余额 → L2StandardBridge（过手）→ L2CrossDomainMessenger（过手）→ L2ToL1MessagePasser`（**沉淀在 L2ToL1MessagePasser**，后续由 `burn()` 销毁）。
- **L1**（未启用 ETH_LOCKBOX）：`OptimismPortal（余额）→ L1StandardBridge（过手）→ 用户`。
- **L1**（启用 ETH_LOCKBOX）：`ETHLockbox → OptimismPortal（donateETH）→ L1StandardBridge（过手）→ 用户`。

### 1.3 路径示意

```text
存款（L1→L2）:
  L1: 用户 --[value]--> L1StandardBridge --[sendMessage{value}]--> L1CrossDomainMessenger
           --[depositTransaction{value}]--> OptimismPortal --[锁定时]--> ETHLockbox（若启用）
  L2: op-node 从 TransactionDeposited 派生存款交易
      --> L2CrossDomainMessenger.relayMessage(value)
      --> L2StandardBridge.finalizeBridgeETH(value)
      --> 接收者 L2 地址余额增加

提款（L2→L1）:
  L2 侧提款发起: 用户 L2 --[value]--> L2StandardBridge --[sendMessage{value}]--> L2CrossDomainMessenger
                   --[initiateWithdrawal{value}]--> L2ToL1MessagePasser（沉淀，后续可批量 burn 销毁）
  L1 侧提款最终确认: 未启用 Lockbox:  OptimismPortal --[callWithMinGas(value)]--> L1StandardBridge --[call(value)]--> 用户 L1
                   启用 Lockbox:    ETHLockbox --[donateETH]--> OptimismPortal --[callWithMinGas(value)]--> L1StandardBridge --[call(value)]--> 用户 L1
```

## 2. L1 到 L2：存款路径

### 2.1 存款路径

**调用链：**

1. **L1StandardBridge**  
   - `receive()` 或 `depositETH()` / `depositETHTo()` 收到 `msg.value`。  
   - 实现：`_initiateETHDeposit(...)` → `_initiateBridgeETH(_from, _to, msg.value, ...)`。

1. **StandardBridge._initiateBridgeETH**（[约 462–492 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/universal/StandardBridge.sol#L462-L492)）

```solidity
// 验证发送的 ETH 数量必须等于桥接数量
require(msg.value == _amount, "...");

_emitETHBridgeInitiated(_from, _to, _amount, _extraData);

// ETH 通过 { value: _amount } 发给 Messenger，Bridge 不保留
messenger.sendMessage{ value: _amount }({
    _target: address(otherBridge),
    _message: abi.encodeWithSelector(this.finalizeBridgeETH.selector, ...),
    _minGasLimit: _minGasLimit
});
```

- **结论**：Bridge 收到 ETH 后**立即**把等额 ETH 用 `sendMessage{ value: _amount }` 转给 **L1CrossDomainMessenger**，自身不存储 ETH。

1. **L1CrossDomainMessenger._sendMessage**（[L1CrossDomainMessenger.sol 约 115–122 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/L1CrossDomainMessenger.sol#L115-L122)）

```solidity
function _sendMessage(...) internal override {
    portal.depositTransaction{ value: _value }({ ... });
}
```

- **结论**：Messenger 把收到的 `_value` 原样以 `depositTransaction{ value: _value }` 转给 **OptimismPortal**，Messenger 在 L1 侧也不做长期存管。

1. **OptimismPortal2.depositTransaction**（[约 734–755 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/OptimismPortal2.sol#L734-L755)）

```solidity
function depositTransaction(...) public payable metered(_gasLimit) {
    if (_isUsingCustomGasToken()) {
        if (msg.value > 0) revert OptimismPortal_NotAllowedOnCGTMode();
    }

    // 若启用 ETHLockbox，将 ETH 转给 Lockbox
    if (_isUsingLockbox()) {
        if (msg.value > 0) ethLockbox.lockETH{ value: msg.value }();
    }
    // ... 发出 TransactionDeposited 等
}
```

- **未启用 Lockbox**：函数为 `payable`，且没有其他转出 `msg.value` 的逻辑 → ETH 留在 **OptimismPortal** 合约余额中。  
- **启用 Lockbox**：仅当 feature 已开启且 `ethLockbox` 地址已配置时，`msg.value` 才会通过 `ethLockbox.lockETH{ value: msg.value }()` 转入 **ETHLockbox**。

**源码依据：**

- [`StandardBridge.sol` 462–492 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/universal/StandardBridge.sol#L462-L492)：`_initiateBridgeETH` 仅做 `messenger.sendMessage{ value: _amount }`，无任何将 ETH 写入 Bridge 自身存储或余额的逻辑。  
- [`L1CrossDomainMessenger.sol` 115 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/L1CrossDomainMessenger.sol#L115)：`portal.depositTransaction{ value: _value }`。  
- [`OptimismPortal2.sol` 750–755 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/OptimismPortal2.sol#L750-L755)：`_isUsingLockbox()` 时 `ethLockbox.lockETH{ value: msg.value }()`，否则无转出。

随后在 L2 侧，这笔存款交易不会把 ETH “直接打给最终用户”，而是会先执行 `L2CrossDomainMessenger.relayMessage(...)`，再调用 `L2StandardBridge.finalizeBridgeETH(...)`，最后由 `L2StandardBridge` 将 ETH 转给用户。

因此：

- 注释「**Bedrock 之后：ETH 存储在 OptimismPortal 中**」在**未启用 ETH_LOCKBOX** 时与源码一致。  
- 注释「**当启用 ETH_LOCKBOX 时，Portal 将收到的 ETH 转存到 Lockbox**」与 750–755 行逻辑一致。

### 2.2 失败与重放

标准桥 ETH 存款在 L2 侧的“成功路径”是：

`L2CrossDomainMessenger.relayMessage(value)` → `L2StandardBridge.finalizeBridgeETH(value)` → 最终接收者 `_to`

但失败路径不能简单理解为“ETH 卡在 `L2StandardBridge`”。结合 `CrossDomainMessenger` 与 `StandardBridge` 当前源码，更准确的语义是：**失败后的 ETH 通常暂留在 `L2CrossDomainMessenger`，后续可通过重放（replay）重试发送**。

#### 2.2.1 `L2CrossDomainMessenger` 前置检查失败

在 `relayMessage(...)` 中，如果 gas 不足或检测到重入，函数不会继续向目标合约发起外部调用，而是直接把消息标记为失败：

- [`CrossDomainMessenger.sol` 354–370 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/universal/CrossDomainMessenger.sol#L354-L370)

```solidity
if (
    !SafeCall.hasMinGas(_minGasLimit, RELAY_RESERVED_GAS + RELAY_GAS_CHECK_BUFFER)
        || xDomainMsgSender != Constants.DEFAULT_L2_SENDER
) {
    failedMessages[versionedHash] = true;
    emit FailedRelayedMessage(versionedHash);
    return;
}
```

此时：

- 首次中继路径下，`msg.value == _value`
- 但 Messenger 尚未把这笔 ETH 向下游 `_target` 发出
- 因而 ETH 留在 **`L2CrossDomainMessenger` 合约余额**

#### 2.2.2 `L2StandardBridge.finalizeBridgeETH(...)` 失败

标准桥场景下，`relayMessage(...)` 的 `_target` 是 `L2StandardBridge`。Messenger 会尝试把 `_value` 连同 `finalizeBridgeETH(...)` 一起打给 Bridge：

- [`CrossDomainMessenger.sol` 373–396 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/universal/CrossDomainMessenger.sol#L373-L396)

```solidity
xDomainMsgSender = _sender;
bool success = SafeCall.call(_target, gasleft() - RELAY_RESERVED_GAS, _value, _message);
xDomainMsgSender = Constants.DEFAULT_L2_SENDER;

if (success) {
    successfulMessages[versionedHash] = true;
    emit RelayedMessage(versionedHash);
} else {
    failedMessages[versionedHash] = true;
    emit FailedRelayedMessage(versionedHash);
}
```

而 `L2StandardBridge.finalizeBridgeETH(...)` 内部，只要入口检查或最终向 `_to` 转账失败，就会整体回滚：

- [`StandardBridge.sol` 332–368 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/universal/StandardBridge.sol#L332-L368)

```solidity
require(paused() == false, "StandardBridge: paused");
require(msg.value == _amount, "StandardBridge: amount sent does not match amount required");
require(_to != address(this), "StandardBridge: cannot send to self");
require(_to != address(messenger), "StandardBridge: cannot send to messenger");

bool success = SafeCall.call(_to, gasleft(), _amount, hex"");
require(success, "StandardBridge: ETH transfer failed");
```

因此，如果出现以下任一情况：

- `_to == address(this)` 或 `_to == address(messenger)`
- `Bridge` 暂停
- `_to` 是拒收 ETH 的合约，导致 `SafeCall.call(_to, ...)` 失败

结果都不是“ETH 半途留在 `L2StandardBridge`”，而是：

- `finalizeBridgeETH(...)` 整体回滚
- `L2CrossDomainMessenger -> L2StandardBridge` 这一层调用返回 `false`
- 消息被 Messenger 标记为 `failed`
- ETH 仍暂留在 **`L2CrossDomainMessenger`**

#### 2.2.3 重放时 ETH 从哪来

重放分支要求：

- [`CrossDomainMessenger.sol` 330–333 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/universal/CrossDomainMessenger.sol#L330-L333)

```solidity
require(msg.value == 0, "CrossDomainMessenger: value must be zero unless message is from a system address");
require(failedMessages[versionedHash], "CrossDomainMessenger: message cannot be replayed");
```

这意味着重放并不会“重新补一笔 ETH”进来。重放时重新向下游发出的 `_value`，来源于：

- **`L2CrossDomainMessenger` 合约余额中，上一次失败后留下的那笔 ETH**

如果重放成功，资金继续沿着：

`L2CrossDomainMessenger` → `L2StandardBridge` → 最终用户 `_to`

如果重放继续失败，则：

- 消息继续保持失败可重放状态
- ETH 继续留在 `L2CrossDomainMessenger`

#### 2.2.4 小结

对当前源码更精确的表述应为：

- 成功路径：`L2CrossDomainMessenger → L2StandardBridge → 用户`
- 失败路径：ETH **通常暂留在 `L2CrossDomainMessenger`**
- 重放时不重新携带 `msg.value`，而是由 Messenger 使用自身余额中的 ETH 再尝试转出
- 若目标合约永久拒收 ETH，则该 ETH 可能长期滞留在 `L2CrossDomainMessenger`

---

## 3. L2 到 L1：提款路径

### 3.1 取款路径

#### 3.1.1 L2 侧提款发起

标准桥 ETH 提款在 L2 侧的合约调用链是：

`L2StandardBridge._initiateBridgeETH(...)` → `L2CrossDomainMessenger.sendMessage(...)` / `_sendMessage(...)` → `L2ToL1MessagePasser.initiateWithdrawal(...)`

对应源码动作可概括为：

1. **L2StandardBridge / StandardBridge**  
   用户调用 `withdraw()` / `withdrawTo()` / `bridgeETHTo()` 后，会进入 `StandardBridge._initiateBridgeETH(...)`，把这笔 ETH 通过 `messenger.sendMessage{ value: _amount }(...)` 发给 `L2CrossDomainMessenger`。

1. **L2CrossDomainMessenger._sendMessage**  
   Messenger 不会把 ETH 直接打到 L1，而是调用 `L2ToL1MessagePasser.initiateWithdrawal{ value: _value }(...)`，把提款请求写入 `sentMessages`。

1. **L2ToL1MessagePasser.initiateWithdrawal**  
   合约构造 `WithdrawalTransaction`，计算 `withdrawalHash`，写入 `sentMessages`，并发出 `MessagePassed` 事件。

这一步结束后，ETH 在 L2 侧的直接停留位置是 **`L2ToL1MessagePasser` 合约余额**；L1 侧此时还没有发生实际放款。

#### 3.1.2 L1 侧提款证明

在 L2 发起提款之后，L1 侧需要先调用 `OptimismPortal.proveWithdrawalTransaction(...)`，把这笔提款“证明到 L1”。

这一阶段的核心不是放款，而是验证：

- 相关 dispute game 是否可用
- output root proof 是否匹配
- `L2ToL1MessagePasser.sentMessages[withdrawalHash]` 是否确实存在于被证明的 storage root 中

证明成功后，Portal 会记录该提款的证明信息与时间戳。此时：

- **L2 侧 ETH** 仍在 `L2ToL1MessagePasser`
- **L1 侧 ETH** 仍在 `OptimismPortal` 或 `ETHLockbox`

也就是说，`proveWithdrawalTransaction(...)` 只是在 L1 建立“这笔提款存在且可在未来最终确认”的依据，**并不直接触发 ETH 支付**。

#### 3.1.3 L1 侧提款最终确认

**OptimismPortal2.finalizeWithdrawalTransaction**（[约 627–641 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/OptimismPortal2.sol#L627-L641)）：

```solidity
if (_isUsingLockbox()) {
    if (_tx.value > 0) ethLockbox.unlockETH(_tx.value);
}
// ...
l2Sender = _tx.sender;
bool success = SafeCall.callWithMinGas(_tx.target, _tx.gasLimit, _tx.value, _tx.data);
```

- **启用 Lockbox**：先 `ethLockbox.unlockETH(_tx.value)`。  
  - **ETHLockbox.unlockETH**（[ETHLockbox.sol 155–176 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/ETHLockbox.sol#L155-L176)）：`sender.donateETH{ value: _value }()`，即把 ETH 转给 **Portal**。  
  - Portal 再通过 `SafeCall.callWithMinGas(_tx.target, ..., _tx.value, _tx.data)` 把该笔 ETH 作为 `msg.value` 转给 `_tx.target`（例如 L1StandardBridge.finalizeBridgeETH）。

- **未启用 Lockbox**：不调用 `unlockETH`，Portal 直接用自身余额执行 `SafeCall.callWithMinGas(..., _tx.value, ...)`，即提款用的 ETH 来自 **Portal 合约余额**（即之前存款留在 Portal 的 ETH）。

- **失败回退路径（启用 Lockbox 时）**：如果 `SafeCall.callWithMinGas(...)` 的下游调用失败，Portal 会把这笔 ETH 再次通过 `ethLockbox.lockETH{ value: _tx.value }()` 锁回 `ETHLockbox`，避免 ETH 滞留在 Portal 中。

**L1StandardBridge.finalizeBridgeETH**（[StandardBridge.sol 331–367 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/universal/StandardBridge.sol#L331-L367)）：

- `require(msg.value == _amount)`，然后用 `SafeCall.call(_to, gasleft(), _amount, hex"")` 把收到的 ETH 转给用户 `_to`。  
- 即 Bridge 不存 ETH，只是从 Portal 收到并立即转给用户。

因此：

- 提款时 ETH 来源与注释一致：**未启用 Lockbox 时来自 OptimismPortal 余额，启用时由 ETHLockbox 经 donateETH 给 Portal 再转给用户**。

---

### 3.2 失败与重放

第三节只讨论 **L1 侧提款最终确认** 这一跳的失败语义。它与第二节不同，不是“失败后可在 Messenger 里重放”的模型，而是 **Portal 侧的一次性最终确认**。

#### 3.2.1 L2 侧提款发起后 ETH 停留位置

提款在 L2 发起后，ETH 不会先去某个“可重放的 Messenger 余额池”，而是会进入 **`L2ToL1MessagePasser`**：

- `L2CrossDomainMessenger._sendMessage(...)` 调用 `L2ToL1MessagePasser.initiateWithdrawal{ value: _value }(...)`
- `L2ToL1MessagePasser` 记录 `withdrawalHash`
- ETH 留在 `L2ToL1MessagePasser` 合约余额中，等待后续 `burn()`

因此，提款路径下 L2 侧的主要沉淀位置是 **`L2ToL1MessagePasser`**，这与第二节存款失败时 ETH 常暂留在 `L2CrossDomainMessenger` 的模型不同。

#### 3.2.2 L1 证明失败时 ETH 停留位置

如果 `proveWithdrawalTransaction(...)` 失败，结果是“这笔提款尚未被 L1 接受为可最终确认的提款”，但不会触发任何跨层资金移动。

此时：

- **L2 侧 ETH** 仍在 `L2ToL1MessagePasser`
- **L1 侧 ETH** 仍保持原状，继续留在 `OptimismPortal` 或 `ETHLockbox`

也就是说，证明失败不是“放款失败”，而是 **提款尚未取得 L1 最终确认资格**。

#### 3.2.3 最终确认前的前置检查

Portal 在真正放款前，会先执行 `checkWithdrawal(...)`。这一步会检查：

- 该提款尚未被最终确认
- 该提款已经被证明
- 证明时间戳有效
- 成熟期已经过去
- 相关争议游戏状态允许最终确认

也就是说，**即便 Portal / Lockbox 里有 ETH，提款也必须先满足证明与成熟条件，才能走到实际支付阶段**。

#### 3.2.4 下游调用失败时 ETH 去哪

在通过前置检查后，Portal 会先把 `finalizedWithdrawals[withdrawalHash]` 标记为 `true`，然后才执行：

```solidity
bool success = SafeCall.callWithMinGas(_tx.target, _tx.gasLimit, _tx.value, _tx.data);
```

这里的 `_tx.target` 在标准桥提款场景下通常是 `L1StandardBridge`，再由 Bridge 把 ETH 转给最终用户。

如果这一步失败：

- **未启用 Lockbox**：ETH 不会再往下游流出，资金仍留在 **OptimismPortal**
- **启用 Lockbox**：Portal 会执行 `ethLockbox.lockETH{ value: _tx.value }()`，把这笔 ETH 锁回 **ETHLockbox**

因此，L1 侧失败后的资金停留位置与 L1 配置直接对应：

- 未启用 `ETH_LOCKBOX`：**留在 Portal**
- 启用 `ETH_LOCKBOX`：**退回 Lockbox**

#### 3.2.5 为什么这里不是“重放”模型

这一跳和第二节最大的不同在于：Portal 会在外部调用前先把提款标记为已最终确认。

因此：

- 它不是 `L2CrossDomainMessenger` 那种“失败后保留为 failed，再允许 replay”的语义
- 即使下游调用失败，这笔提款也已经进入“已最终确认”状态
- `WithdrawalFinalized(withdrawalHash, success)` 会记录这次最终确认的执行结果

更准确地说，**L1 侧提款最终确认是“一次性结算”，不是“失败后继续重放”的消息通道**。

#### 3.2.6 小结

- 第三节关心的是 **L1 放款来源与 L1 失败回退**
- 提款在 L2 发起后，ETH 先停留在 `L2ToL1MessagePasser`
- `proveWithdrawalTransaction(...)` 只负责建立提款存在性的 L1 证明，不直接放款
- 标准桥场景下，`_tx.target` 通常是 `L1StandardBridge`，Bridge 只是过手，最终收款人是 `_to`
- L1 侧失败后，ETH 要么留在 `OptimismPortal`，要么回到 `ETHLockbox`
- 这一跳不存在第二节那种 `failedMessages + replay` 的重放路径

---

## 4. 小结

- **L1StandardBridge**：不持有 ETH，存款时把 `msg.value` 经 Messenger 转给 Portal。  
- **L1CrossDomainMessenger**：不持有 ETH，把收到的 value 转给 Portal.depositTransaction。  
- **OptimismPortal**：  
  - 未启用 `ETH_LOCKBOX`：存款 ETH 留在 Portal；提款时从 Portal 余额支出。  
  - 启用 `ETH_LOCKBOX`：存款时通过 `lockETH` 转给 ETHLockbox；提款时通过 `unlockETH` → `donateETH` 从 Lockbox 转回 Portal 再付给用户。
- **L2 标准桥到账路径**：并非“Portal 事件后直接记账给用户”，而是 `L2CrossDomainMessenger → L2StandardBridge → 用户`；失败消息可重放，失败后的 ETH 通常暂留在 `L2CrossDomainMessenger`。  
- **模式限制**：若系统启用 `CUSTOM_GAS_TOKEN`，原生 ETH 的存款与提款会被禁用，本文结论不适用于该模式。

据此，文档与注释中关于「Bedrock 之后 ETH 存在 OptimismPortal」「启用 ETH_LOCKBOX 时转存到 Lockbox」「ETH 通过 OptimismPortal 发送到 L2」的表述与当前源码行为一致，可视为正确。

---

## 附录 A. CUSTOM_GAS_TOKEN 模式补充说明

`CUSTOM_GAS_TOKEN` 是一种系统模式。启用后，这条链不再把原生 ETH 当作 gas token 使用。

相关规范可参考：

- [OP Stack Specification: Custom Gas Token](https://specs.optimism.io/experimental/custom-gas-token.html)

在默认的 native ETH 模式下：

- L1→L2 可以通过 `OptimismPortal.depositTransaction(...)` 携带 `msg.value`
- L2→L1 的提款在 `OptimismPortal.finalizeWithdrawalTransaction(...)` 中也可以携带 `_tx.value`

而一旦开启 `CUSTOM_GAS_TOKEN`，`OptimismPortal` 会禁止原生 ETH 的存款 / 提款 value 路径。也就是说，这条链会围绕“自定义 gas 代币”运行。本文前面分析的“ETH 如何在 Portal / Lockbox / StandardBridge 之间流动”的结论，也就**不再适用**。

### A.1 feature 定义

`Features.sol` 对该 feature 的定义非常直接：

- 源码：[`Features.sol` 14–17 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/libraries/Features.sol#L14-L17)
- 规范：[OP Stack Specification / Custom Gas Token / `Properties of a Gas Paying Token`](https://specs.optimism.io/experimental/custom-gas-token.html)

两者都指向同一个结论：当 `CUSTOM_GAS_TOKEN` 激活时，系统不再把原生 ETH 当作 gas 支付资产。

### A.2 Portal 如何判断是否处于该模式

`OptimismPortal2` 通过 `systemConfig.isFeatureEnabled(Features.CUSTOM_GAS_TOKEN)` 判断：

- 源码：[`OptimismPortal2.sol` 810–813 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/OptimismPortal2.sol#L810-L813)
- 规范：[OP Stack Specification / Custom Gas Token / `Configuring the Gas Paying Token`](https://specs.optimism.io/experimental/custom-gas-token.html)

```solidity
function _isUsingCustomGasToken() internal view returns (bool) {
    return systemConfig.isFeatureEnabled(Features.CUSTOM_GAS_TOKEN);
}
```

### A.3 对 ETH 存款的直接影响

在 `depositTransaction(...)` 中，如果系统处于 `CUSTOM_GAS_TOKEN` 模式，则只要 `msg.value > 0` 就会直接 revert：

- 源码：[`OptimismPortal2.sol` 746–749 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/OptimismPortal2.sol#L746-L749)
- 规范：[OP Stack Specification / Custom Gas Token / `OptimismPortal` -> `depositTransaction`](https://specs.optimism.io/experimental/custom-gas-token.html)

```solidity
if (_isUsingCustomGasToken()) {
    if (msg.value > 0) revert OptimismPortal_NotAllowedOnCGTMode();
}
```

这意味着 `L1StandardBridge -> L1CrossDomainMessenger -> OptimismPortal` 这条 ETH 存款路径会在 Portal 处被拒绝。

因此，不会再出现“ETH 最终沉淀在 Portal 或 ETHLockbox”这一结果。

### A.4 对 ETH 提款最终确认的直接影响

在 `finalizeWithdrawalTransaction(...)` 中，如果系统处于 `CUSTOM_GAS_TOKEN` 模式，则只要 `_tx.value > 0` 也会直接 revert：

- 源码：[`OptimismPortal2.sol` 601–604 行](https://github.com/ethereum-optimism/optimism/blob/b053ac1dd6e5e8b3e6d3d941c3300643c9d6d18b/packages/contracts-bedrock/src/L1/OptimismPortal2.sol#L601-L604)
- 规范：[OP Stack Specification / Custom Gas Token / `CrossDomainMessenger` 与 `StandardBridge`](https://specs.optimism.io/experimental/custom-gas-token.html)

```solidity
if (_isUsingCustomGasToken()) {
    if (_tx.value > 0) revert OptimismPortal_NotAllowedOnCGTMode();
}
```

这意味着即便 L2 上构造了一笔带 `_tx.value` 的 native ETH 提款消息，Portal 也不会在 L1 释放 ETH。

因此，本文主文中“提款时 ETH 来自 Portal 或 ETHLockbox”的结论，仅适用于 **native ETH 模式**。

### A.5 如何理解它和本文主结论的关系

可以把系统分成两种模式来理解：

- **native ETH 模式**：ETH 是 gas token，本文主文分析成立
- **`CUSTOM_GAS_TOKEN` 模式**：链改用自定义 gas 代币，Portal 禁止 native ETH 的 value 型存款与提款，本文主文不适用

这也和规范中的 user flow 描述一致：

- 规范在 [`When ETH is the Native Asset`](https://specs.optimism.io/experimental/custom-gas-token.html) 和 [`When an ERC20 Token is the Native Asset`](https://specs.optimism.io/experimental/custom-gas-token.html) 两组流程里，明确区分了 ETH 原生资产链与 custom gas token 链的用户入口。

因此，本文所有关于：

- “ETH 存在 `OptimismPortal`”
- “启用 `ETH_LOCKBOX` 时 ETH 转存到 `ETHLockbox`”
- “提款时 Portal / Lockbox 向用户支付 ETH”

的结论，都应默认带上前提：**链未启用 `CUSTOM_GAS_TOKEN`**。
