// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

// External
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Internal
import { AccountRegistry } from "src/internals/AccountRegistry.sol";
import { CurrencyManager } from "src/internals/CurrencyManager.sol";
import { FeeManager } from "src/internals/FeeManager.sol";
import { NonceManager } from "src/internals/NonceManager.sol";

// Interfaces
import { IFireFlyExchange } from "src/interfaces/IFireFlyExchange.sol";
import { IERC6551Registry } from "erc6551/src/interfaces/IERC6551Registry.sol";

// Libraries
import { OrderStructs } from "src/libraries/OrderStructs.sol";

// Enums
import { QuoteType } from "src/enums/QuoteType.sol";
import { CollectionType } from "src/enums/CollectionType.sol";

// Constants
import { NATIVE_TOKEN } from "src/constants/AddressConstants.sol";
import { OPERATOR_ROLE, CURRENCY_ROLE, COLLECTION_ROLE } from "src/constants/RoleConstants.sol";

contract FireFlyExchange is
    IFireFlyExchange,
    AccessControl,
    AccountRegistry,
    CurrencyManager,
    NonceManager,
    EIP712,
    FeeManager,
    ReentrancyGuard
{
    using OrderStructs for OrderStructs.Maker;

    /**
     * @notice Constructor
     */
    constructor(
        string memory name_,
        IERC6551Registry registry_,
        address implementation_
    )
        AccountRegistry(registry_, implementation_)
        EIP712(name_, "1")
    {
        address sender = _msgSender();
        bytes32 operatorRole = OPERATOR_ROLE;
        bytes32 currencyRole = CURRENCY_ROLE;
        bytes32 collectionRole = COLLECTION_ROLE;

        _grantRole(DEFAULT_ADMIN_ROLE, sender);
        _grantRole(operatorRole, sender);
        _grantRole(currencyRole, address(0));

        _setRoleAdmin(currencyRole, operatorRole);
        _setRoleAdmin(collectionRole, operatorRole);
    }

    /**
     * @inheritdoc IFireFlyExchange
     */
    function executeOrder(
        OrderStructs.Maker calldata maker_,
        OrderStructs.Taker calldata taker_
    )
        external
        payable
        nonReentrant
    {
        bytes32 makerHash = maker_.hash();
        address buyer = taker_.recipient;

        // Check the maker ask order
        _validateBasicOrderInfo(maker_);

        _validateSignature(maker_.signer, makerHash, maker_.makerSignature);

        if (maker_.collectionType == CollectionType.ERC6551) {
            _validateAssetsInsideAccount(maker_.collection, maker_.tokenId, maker_.assets, maker_.values);
        }

        if (maker_.quoteType == QuoteType.Bid) _validateSignature(buyer, makerHash, taker_.takerSignature);

        // prevents replay
        _setUsed(maker_.signer, maker_.orderNonce);

        // Execute transfer currency
        _transferFeesAndFunds(maker_.currency, buyer, maker_.signer, maker_.price);

        // Execute transfer token collection
        _transferNonFungibleToken(maker_.collection, maker_.signer, buyer, maker_.tokenId);
    }

    /**
     * @notice Transfer fees and funds to protocol recipient, and seller
     * @param currency_ currency being used for the purchase (e.g., WETH/USDC)
     * @param from_ sender of the funds
     * @param to_ seller's recipient
     * @param amount_ amount being transferred (in currency)
     */
    function _transferFeesAndFunds(address currency_, address from_, address to_, uint256 amount_) internal {
        if (currency_ == NATIVE_TOKEN) _receiveNative(amount_);

        // Initialize the final amount that is transferred to seller
        uint256 finalSellerAmount = amount_;

        // 1. Protocol fee

        // 2. Transfer final amount (post-fees) to seller
        {
            _transferCurrency(currency_, from_, to_, finalSellerAmount);
        }
    }

    /**
     * @notice Verify the validity of the maker order
     * @param makerAsk maker ask
     */
    function _validateBasicOrderInfo(OrderStructs.Maker calldata makerAsk) private view {
        // Verify the price is not 0
        if (makerAsk.price == 0) revert Exchange__ZeroValue();

        // Verify order timestamp
        if (makerAsk.startTime > block.timestamp || makerAsk.endTime < block.timestamp) revert Exchange__OutOfRange();

        // Verify whether the currency is whitelisted
        if (!hasRole(CURRENCY_ROLE, makerAsk.currency)) revert Exchange__InvalidCurrency();

        if (!hasRole(COLLECTION_ROLE, makerAsk.collection)) revert Exchange__InvalidCollection();

        // Verify whether order nonce has expired
        if (makerAsk.orderNonce < _minNonce[makerAsk.signer]) revert Exchange__InvalidNonce();

        if (_isUsed(makerAsk.signer, makerAsk.orderNonce)) revert Exchange__InvalidNonce();
    }

    function _validateSignature(address signer_, bytes32 hash_, bytes calldata signature_) internal view {
        (address recoveredAddress,) = ECDSA.tryRecover(_hashTypedDataV4(hash_), signature_);

        // Verify the validity of the signature
        if (recoveredAddress == address(0) || recoveredAddress != signer_) revert Exchange__InvalidSigner();
    }

    function _validateAssetsInsideAccount(
        address collection,
        uint256 tokenId,
        address[] calldata assets,
        uint256[] calldata values
    )
        internal
        view
    {
        address erc6551Account = _registry.account(_implementation, 1, collection, tokenId, 0);
        uint256 length = assets.length;
        if (length != values.length) revert Exchange__LengthMisMatch();

        for (uint256 i = 0; i < length;) {
            if (erc6551Account != _safeOwnerOf(assets[i], values[i])) {
                revert Exchange__InvalidAsset();
            }
            unchecked {
                ++i;
            }
        }
    }
}
