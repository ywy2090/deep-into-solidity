// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SimpleTransparentProxy
 * @dev 这是一个用于教学的透明代理精简实现。
 * 它展示了如何通过判断 msg.sender 来解决函数选择器冲突。
 */
contract SimpleTransparentProxy {
    // ------------------------------------------------------------------------
    // 存储槽 (Storage Slots)
    // ------------------------------------------------------------------------

    // 根据 ERC-1967 标准计算的存储槽位置
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 private constant ADMIN_SLOT =
        0xb5312768d8dd97f004189ee800e40525539f00ca465733d915ba9d5da3f98700;

    // ------------------------------------------------------------------------
    // 事件
    // ------------------------------------------------------------------------

    event Upgraded(address indexed implementation);
    event AdminChanged(address previousAdmin, address newAdmin);

    // ------------------------------------------------------------------------
    // 构造函数
    // ------------------------------------------------------------------------

    constructor(address _logic, address _admin) {
        require(_logic != address(0), "Logic address cannot be zero");
        require(_admin != address(0), "Admin address cannot be zero");

        _setImplementation(_logic);
        _setAdmin(_admin);
    }

    // ------------------------------------------------------------------------
    // “透明”逻辑的核心修饰符
    // ------------------------------------------------------------------------

    /**
     * @dev 这是透明代理的核心逻辑！
     * 如果调用者不是管理员，则立即回退到 _delegate 函数，将请求转发给逻辑合约。
     * 这确保了普通用户永远无法调用代理合约的管理函数，即使函数名相同。
     */
    modifier ifAdmin() {
        if (msg.sender == _getAdmin()) {
            // 如果是管理员，执行代理合约的逻辑
            _;
        } else {
            // 如果是普通用户，立刻转发给逻辑合约
            _delegate(_getImplementation());
        }
    }

    // ------------------------------------------------------------------------
    // 管理员接口 (Admin Interface)
    // ------------------------------------------------------------------------

    /**
     * @dev 升级逻辑合约地址。
     * 使用 ifAdmin 修饰符：如果是用户调用此函数（无论有意还是无意），
     * 请求会被直接转发到逻辑合约，而不是执行这里的逻辑。
     */
    function upgradeTo(address newImplementation) external payable ifAdmin {
        require(newImplementation != address(0), "New implementation is zero");
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
    }

    /**
     * @dev 修改管理员地址。
     */
    function changeAdmin(address newAdmin) external payable ifAdmin {
        require(newAdmin != address(0), "New admin is zero");
        emit AdminChanged(_getAdmin(), newAdmin);
        _setAdmin(newAdmin);
    }

    /**
     * @dev 获取当前管理员地址（仅管理员可调用）。
     */
    function admin() external payable ifAdmin returns (address) {
        return _getAdmin();
    }

    /**
     * @dev 获取当前逻辑合约地址（仅管理员可调用）。
     */
    function implementation() external payable ifAdmin returns (address) {
        return _getImplementation();
    }

    // ------------------------------------------------------------------------
    // 转发逻辑 (Delegation Logic)
    // ------------------------------------------------------------------------

    /**
     * @dev fallback 函数处理所有无法匹配到的函数调用。
     * 对于普通用户，这是主要的入口点。
     * 对于管理员，如果调用了不存在的管理函数，也会进入这里，但我们通过 _delegate 转发。
     * 注意：标准的透明代理中，管理员如果调用了不存在的函数，通常不会转发，而是 revert。
     * 为了简化教学，这里统一转发。
     */
    fallback() external payable {
        _delegate(_getImplementation());
    }

    /**
     * @dev 接收纯 ETH 转账
     */
    receive() external payable {
        _delegate(_getImplementation());
    }

    /**
     * @dev 使用内联汇编进行 delegatecall。
     * 这是代理合约的标准实现，它将当前调用的所有上下文（msg.data, gas）
     * 转发给 implementation，并将结果原样返回。
     */
    function _delegate(address _impl) internal {
        assembly {
            // 1. 复制 calldata 到内存
            // calldatacopy(dest, offset, size)
            calldatacopy(0, 0, calldatasize())

            // 2. 执行 delegatecall
            // delegatecall(gas, address, argsOffset, argsSize, retOffset, retSize)
            // out 和 outsize 设为 0，因为我们要自己处理返回数据
            let result := delegatecall(gas(), _impl, 0, calldatasize(), 0, 0)

            // 3. 复制返回数据到内存
            // returndatacopy(dest, offset, size)
            returndatacopy(0, 0, returndatasize())

            // 4. 根据执行结果处理返回
            switch result
            // 如果 delegatecall 成功 (result == 1)，则 return 返回数据
            case 1 {
                return(0, returndatasize())
            }
            // 如果 delegatecall 失败 (result == 0)，则 revert 并附带错误信息
            case 0 {
                revert(0, returndatasize())
            }
        }
    }

    // ------------------------------------------------------------------------
    // 存储读写辅助函数 (Storage Helpers)
    // ------------------------------------------------------------------------

    function _getAdmin() internal view returns (address adm) {
        bytes32 slot = ADMIN_SLOT;
        assembly {
            adm := sload(slot)
        }
    }

    function _setAdmin(address newAdmin) internal {
        bytes32 slot = ADMIN_SLOT;
        assembly {
            sstore(slot, newAdmin)
        }
    }

    function _getImplementation() internal view returns (address impl) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            impl := sload(slot)
        }
    }

    function _setImplementation(address newImpl) internal {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            sstore(slot, newImpl)
        }
    }
}
