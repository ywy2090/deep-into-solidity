# ERC3643 类图

```plantuml
classDiagram
    direction TB

    %% ===== Core Token =====
    class IToken {
        <<interface>>
        +name() string
        +symbol() string
        +decimals() uint8
        +totalSupply() uint256
        +balanceOf(address) uint256
        +transfer(address, uint256) bool
        +approve(address, uint256) bool
        +transferFrom(address, address, uint256) bool
        +pause()
        +unpause()
        +setIdentityRegistry(IIdentityRegistry)
        +setCompliance(ICompliance)
        +forcedTransfer(address, address, uint256)
        +mint(address, uint256)
        +burn(address, uint256)
        +recoveryAddress(address, address, address)
        +batchTransfer(address[], uint256[])
        +freezePartialTokens(address, uint256)
        +unfreezePartialTokens(address, uint256)
        +setAddressFrozen(address, bool)
    }

    class Token {
        -_identityRegistry IIdentityRegistry
        -_compliance ICompliance
        -_frozenTokens mapping
        -_frozen mapping
        -_paused bool
        +identityRegistry() IIdentityRegistry
        +compliance() ICompliance
        +getFrozenTokens(address) uint256
        +isFrozen(address) bool
    }

    %% ===== Identity Registry =====
    class IIdentityRegistry {
        <<interface>>
        +registerIdentity(address, IIdentity, uint16)
        +deleteIdentity(address)
        +updateIdentity(address, IIdentity)
        +updateCountry(address, uint16)
        +contains(address) bool
        +isVerified(address) bool
        +identity(address) IIdentity
        +investorCountry(address) uint16
        +identityStorage() IIdentityRegistryStorage
        +issuersRegistry() ITrustedIssuersRegistry
        +topicsRegistry() IClaimTopicsRegistry
    }

    class IdentityRegistry {
        -_identityStorage IIdentityRegistryStorage
        -_issuersRegistry ITrustedIssuersRegistry
        -_topicsRegistry IClaimTopicsRegistry
        +setIdentityRegistryStorage(IIdentityRegistryStorage)
        +setClaimTopicsRegistry(IClaimTopicsRegistry)
        +setTrustedIssuersRegistry(ITrustedIssuersRegistry)
    }

    %% ===== Identity Registry Storage =====
    class IIdentityRegistryStorage {
        <<interface>>
        +addIdentityToStorage(address, IIdentity, uint16)
        +removeIdentityFromStorage(address)
        +modifyStoredIdentity(address, IIdentity)
        +modifyStoredInvestorCountry(address, uint16)
        +storedIdentity(address) IIdentity
        +storedInvestorCountry(address) uint16
        +bindIdentityRegistry(address)
        +unbindIdentityRegistry(address)
        +linkedIdentityRegistries() address[]
    }

    class IdentityRegistryStorage {
        -_identities mapping~address => IIdentity~
        -_investorCountries mapping~address => uint16~
        -_identityRegistries address[]
    }

    %% ===== Trusted Issuers Registry =====
    class ITrustedIssuersRegistry {
        <<interface>>
        +addTrustedIssuer(IClaimIssuer, uint256[])
        +removeTrustedIssuer(IClaimIssuer)
        +updateIssuerClaimTopics(IClaimIssuer, uint256[])
        +getTrustedIssuers() IClaimIssuer[]
        +isTrustedIssuer(address) bool
        +getTrustedIssuerClaimTopics(IClaimIssuer) uint256[]
        +hasClaimTopic(address, uint256) bool
    }

    class TrustedIssuersRegistry {
        -_trustedIssuers IClaimIssuer[]
        -_trustedIssuerClaimTopics mapping
        -_claimTopicsToTrustedIssuers mapping
    }

    %% ===== Claim Topics Registry =====
    class IClaimTopicsRegistry {
        <<interface>>
        +addClaimTopic(uint256)
        +removeClaimTopic(uint256)
        +getClaimTopics() uint256[]
    }

    class ClaimTopicsRegistry {
        -_claimTopics uint256[]
    }

    %% ===== Compliance =====
    class ICompliance {
        <<interface>>
        +bindToken(address)
        +unbindToken(address)
        +canTransfer(address, address, uint256) bool
        +transferred(address, address, uint256)
        +created(address, uint256)
        +destroyed(address, uint256)
        +addModule(address)
        +removeModule(address)
        +getModules() address[]
    }

    class ModularCompliance {
        -_tokenBound address
        -_modules address[]
        +callModuleFunction(bytes, address)
    }

    class IComplianceModule {
        <<interface>>
        +moduleCheck(address, address, uint256, address) bool
        +moduleMintAction(address, uint256)
        +moduleBurnAction(address, uint256)
        +moduleTransferAction(address, address, uint256)
        +name() string
        +isPlugAndPlay() bool
    }

    class AbstractModule {
        <<abstract>>
        -_compliance address
        #onlyComplianceCall()
    }

    %% ===== Common Compliance Modules =====
    class CountryAllowModule {
        -_allowedCountries mapping
        +addAllowedCountry(uint16)
        +removeAllowedCountry(uint16)
        +batchAllowCountries(uint16[])
    }

    class MaxBalanceModule {
        -_maxBalance mapping
        +setMaxBalance(uint256)
        +presetModuleState(address, uint256)
    }

    class SupplyLimitModule {
        -_supplyLimit uint256
        +setSupplyLimit(uint256)
    }

    class TimeTransferLimitsModule {
        -_limits mapping
        +setTimeTransferLimit(uint32, uint256)
    }

    %% ===== ONCHAINID =====
    class IIdentity {
        <<interface>>
        +addKey(bytes32, uint256, uint256) bool
        +removeKey(bytes32) bool
        +addClaim(uint256, uint256, address, bytes, bytes, string) bytes32
        +removeClaim(bytes32) bool
        +execute(address, uint256, bytes) uint256
        +approve(uint256, bool) bool
        +getKey(bytes32) tuple
        +getClaim(bytes32) tuple
        +getClaimIdsByTopic(uint256) bytes32[]
        +keyHasPurpose(bytes32, uint256) bool
    }

    class Identity {
        -_keys mapping~bytes32 => Key~
        -_claims mapping~bytes32 => Claim~
        -_claimsByTopic mapping~uint256 => bytes32[]~
        -_keysByPurpose mapping~uint256 => bytes32[]~
        -_executions mapping~uint256 => Execution~
    }

    class IClaimIssuer {
        <<interface>>
        +isClaimValid(IIdentity, uint256, bytes, bytes) bool
        +revokeClaimBySignature(bytes)
        +revokeClaim(bytes32, address)
        +isClaimRevoked(bytes) bool
    }

    class ClaimIssuer {
        -_revokedClaims mapping~bytes => bool~
    }

    %% ===== Data Structures =====
    class Key {
        <<struct>>
        +purposes uint256[]
        +keyType uint256
        +key bytes32
    }

    class Claim {
        <<struct>>
        +topic uint256
        +scheme uint256
        +issuer address
        +signature bytes
        +data bytes
        +uri string
    }

    %% ===== Relationships =====
    IToken <|.. Token : implements
    Token --> IIdentityRegistry : uses
    Token --> ICompliance : uses

    IIdentityRegistry <|.. IdentityRegistry : implements
    IdentityRegistry --> IIdentityRegistryStorage : uses
    IdentityRegistry --> ITrustedIssuersRegistry : uses
    IdentityRegistry --> IClaimTopicsRegistry : uses

    IIdentityRegistryStorage <|.. IdentityRegistryStorage : implements
    ITrustedIssuersRegistry <|.. TrustedIssuersRegistry : implements
    IClaimTopicsRegistry <|.. ClaimTopicsRegistry : implements

    ICompliance <|.. ModularCompliance : implements
    ModularCompliance --> IComplianceModule : manages

    IComplianceModule <|.. AbstractModule : implements
    AbstractModule <|-- CountryAllowModule : extends
    AbstractModule <|-- MaxBalanceModule : extends
    AbstractModule <|-- SupplyLimitModule : extends
    AbstractModule <|-- TimeTransferLimitsModule : extends

    IIdentity <|.. Identity : implements
    IClaimIssuer <|.. ClaimIssuer : implements
    IIdentity <|-- IClaimIssuer : extends

    Identity --> Key : contains
    Identity --> Claim : contains

    IdentityRegistryStorage --> IIdentity : stores
    TrustedIssuersRegistry --> IClaimIssuer : manages
    IdentityRegistry ..> IIdentity : verifies
```
