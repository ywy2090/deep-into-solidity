// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ====================================================================
// 1. 基础抽象合约：UUPSUpgradeable
// 所有的逻辑合约（Implementation）都必须继承这个合约，否则无法升级
// ====================================================================

abstract contract UUPSUpgradeable {
    // ERC-1967 标准存储槽：bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /**
     * @dev 获取当前逻辑合约地址
     */
    function _getImplementation() internal view returns (address impl) {
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
    }

    /**
     * @dev 升级合约的核心函数。
     * 注意：这个函数是在逻辑合约中定义的，但是通过 delegatecall 运行在代理合约的上下文中。
     * 因此，它修改的是代理合约的 storage！
     */
    function upgradeTo(address newImplementation) external {
        // 1. 权限检查
        // 必须由子合约实现具体的权限控制（例如 onlyOwner）
        _authorizeUpgrade(newImplementation);

        // 2. 验证新合约是否安全（防变砖机制）
        // 在生产环境中，这里必须检查 newImplementation 是否也支持 UUPS。
        // 为了简化代码，这里省略了复杂的 EIP-1822 检查，但这是 UUPS 最危险的地方！
        require(newImplementation != address(0), "Invalid address");

        // 3. 修改存储槽（这是修改代理合约的状态）
        _setImplementation(newImplementation);
    }

    /**
     * @dev 必须由子合约覆盖的虚拟函数，用于权限控制。
     * 如果不实现这个检查，任何人都能升级你的合约并窃取资金！
     */
    function _authorizeUpgrade(address newImplementation) internal virtual;

    /**
     * @dev 底层设置实现地址
     */
    function _setImplementation(address newImplementation) private {
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
    }
}

// ====================================================================
// 2. 具体的逻辑合约：LogicV1
// ====================================================================

contract LogicV1 is UUPSUpgradeable {
    // 状态变量
    uint256 public val;
    address public owner;

    // 初始化函数（替代构造函数）
    function initialize() public {
        require(owner == address(0), "Already initialized");
        owner = msg.sender;
        val = 10;
    }

    // 必须实现权限控制逻辑
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override {
        require(msg.sender == owner, "Only owner can upgrade");
    }

    // 业务逻辑
    function doSomething(uint256 _val) public {
        val = _val;
    }

    // 版本标识（用于测试升级是否成功）
    function version() public pure returns (string memory) {
        return "V1";
    }
}

// ====================================================================
// 3. UUPS 代理合约：UUPSProxy
// 这是一个“傻瓜”代理，它没有任何升级逻辑，只有 delegatecall
// ====================================================================

contract UUPSProxy {
    // 存储槽必须与 UUPSUpgradeable 中定义的一致
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /**
     * @dev 构造函数：设置初始逻辑合约
     */
    constructor(address _implementation, bytes memory _data) payable {
        // 1. 存储初始逻辑合约地址到指定 Slot
        assembly {
            sstore(_IMPLEMENTATION_SLOT, _implementation)
        }

        // 2. 如果有初始化数据，立即执行 initialize
        if (_data.length > 0) {
            (bool success, ) = _implementation.delegatecall(_data);
            require(success, "Initialization failed");
        }
    }

    /**
     * @dev 标准的 fallback 转发逻辑。
     * 无论调用什么函数（包括 upgradeTo），都会被转发给逻辑合约。
     */
    fallback() external payable {
        _delegate(_getImplementation());
    }

    receive() external payable {
        _delegate(_getImplementation());
    }

    /**
     * @dev 读取当前逻辑合约地址
     */
    function _getImplementation() internal view returns (address impl) {
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
    }

    /**
     * @dev 汇编实现的 delegatecall
     */
    function _delegate(address _impl) internal {
        assembly {
            // 复制 calldata
            calldatacopy(0, 0, calldatasize())

            // 转发调用
            let result := delegatecall(gas(), _impl, 0, calldatasize(), 0, 0)

            // 复制返回数据
            returndatacopy(0, 0, returndatasize())

            switch result
            case 1 {
                return(0, returndatasize())
            }
            case 0 {
                revert(0, returndatasize())
            }
        }
    }
}
