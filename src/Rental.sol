// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import { ERC721 } from "solmate/tokens/ERC721.sol";
import {IERC721TokenReceiver} from "./interfaces/IERC721TokenReceiver.sol";

/// @title Rental
/// @author gstenger98, andreas <andreas@nascent.xyz>
/// @notice A Collateral-based ERC721 Token Rental Protocol
contract Rental {

    /// -------------------------------------------- ///
    /// ---------------- IMMUTABLES ---------------- ///
    /// -------------------------------------------- ///

    /// @notice The address of the original owner
    address public immutable lenderAddress;

    /// @notice The address of the tempory borrower
    address public immutable borrowerAddress;

    /// @notice The collection of the NFT to lend
    ERC721 public immutable nftCollection;

    /// @notice The the id of the NFT within the collection
    uint256 public immutable nftId;

    /// @notice The expiration time of the rental
    /// @dev Measured as a future block timestamp
    uint256 public immutable dueDate;

    /// @notice The amount of ETH the borrower must pay the lender in order to rent the NFT if returned on time
    uint256 public immutable rentalPayment;

    /// @notice The amount of additional ETH the lender requires as collateral
    uint256 public immutable collateral;

    /// @notice The amount of time the collateral will be linearly paid out over if the NFT isn't returned on time
    uint256 public immutable collateralPayoutPeriod;

    /// @notice The contract deployoor specifies a period by which the assets must be deposited else the contract is voided
    uint256 public immutable nullificationTime;

    /// -------------------------------------------- ///
    /// ------------------- STATE ------------------ ///
    /// -------------------------------------------- ///

    /// @notice The time when the rental contract officially begins (NFT and rental payment just sent to borrower and lender)
    uint256 public rentalStartTime; // contractInitializationTime, startingTime, initializationTime

    /// @notice The amount of collateral left in the contract
    uint256 public collateralLeft; // should collateralLeft and rentalStartTime be public or private?

    /// @notice Store if the NFT has been deposited
    bool public nftIsDeposited; // really, the contract should have the capacity to look up if it is the nft owner

    /// @notice Store if the borrower's required ETH has been deposited
    bool public ethIsDeposited; // the contract should have the capacity to look up how much eth has been deposited into it

    /// -------------------------------------------- ///
    /// ------------------- EVENTS ----------------- ///
    /// -------------------------------------------- ///

    event ContractNullified();
    event RentalStarted();
    event NftReturned();
    event PayoutPeriodBegins();
    event PayoutPeriodEnds();

    /// -------------------------------------------- ///
    /// ------------------- ERRORS ----------------- ///
    /// -------------------------------------------- ///

    error InsufficientValue();
    error FailedToSendEther();
    error Unauthorized();
    error IncorrectState();
    error NotEligibleForRewards();
    error InvalidToken();

    error BadTimeBounds();

    error AlreadyDeposited();
    error NonLender();
    error NonTokenOwner();

    /// -------------------------------------------- ///
    /// ---------------- CONSTRUCTOR --------------- ///
    /// -------------------------------------------- ///

    /// @notice Permissionless Rental Creation
    constructor(
        address _lenderAddress,
        address _borrowerAddress,
        address _nftAddress,
        uint256 _nftId,
        uint256 _dueDate,
        uint256 _rentalPayment,
        uint256 _collateral,
        uint256 _collateralPayoutPeriod,
        uint256 _nullificationTime
    ) {

        // Require that the _lenderAddress owns the specified NFT
        if (ERC721(_nftAddress).ownerOf(_nftId) != _lenderAddress) revert NonTokenOwner();

        // Require that the _borrowerAddress has more than _rentalPayment + _collateral
        if (_borrowerAddress.balance < _rentalPayment.add(_collateral)) revert InsufficientValue();

        // Require that the expiry is in the future
        if (_dueDate < block.timestamp) revert BadTimeBounds();
        
        // Assign our contract parameters
        lenderAddress = payable(_lenderAddress);
        borrowerAddress = payable(_borrowerAddress);
        nftCollection = ERC721(_nftAddress);
        nftId = _nftId;
        dueDate = _dueDate;
        rentalPayment = _rentalPayment;
        collateral = _collateral;
        collateralPayoutPeriod = _collateralPayoutPeriod;
        nullificationTime = _nullificationTime;
    }

    /// -------------------------------------------- ///
    /// -------------- EXTERNAL LOGIC -------------- ///
    /// -------------------------------------------- ///

    /// @notice Lender must deposit the ERC721 token to enable lending
    /// @notice First step after Rental Contract Construction
    function depositNft() external payable {
        // We don't accept double deposits
        if (nftIsDeposited) revert AlreadyDeposited();

        // The ERC721 Token Depositer must be the lender
        if (msg.sender != lenderAddress) revert NonLender();

        // If the nullification time has passed, emit this and terminate the contract
        if (block.timestamp >= nullificationTime) {
            nullifyContract();
        }

        // If the borrower has not deposited their required ETH yet, send the NFT to the contract 
        if (!ethIsDeposited) {
            nftCollection.safeTransferFrom(msg.sender, address(this), nftId);
            nftIsDeposited = true;
        } else {
            nftCollection.safeTransferFrom(msg.sender, borrowerAddress, nftId);
            // Send lender the ETH rental payment from the contract (keeping collateral stored)
            payable(lenderAddress).transfer(rentalPayment);
            nftIsDeposited = true;
            emit RentalStarted();
            _beginRental();
        }
    }

    // After the contract is constructed with the parameters informally agreed upon off-chain
    // the borrower must deposit their required ETH in order to receive the NFT.

    function depositEth() external payable {

        // Require that the sender is the borrower and that the payment amount is correct
        require(!ethIsDeposited, "The ETH has already been deposited");
        require(msg.sender == borrowerAddress, "The msg sender does not match the borrower");
        require(msg.value >= rentalPayment.add(collateral), "The msg value is less than the payment plus collateral");

        // If the current time is past the nullification contract, nullify the contract
        if (block.timestamp >= nullificationTime) {
            // Send the borrower all of their ETH back
            payable(msg.sender).transfer(msg.value);
            // Nullify the contract
            nullifyContract();
        }

        // If the borrower sent too much ETH, immediately refund them the extra ETH they sent 
        if (msg.value > rentalPayment.add(collateral)) {
            payable(msg.sender).transfer(msg.value.sub(rentalPayment.add(collateral)));
        }

        // If the lender has not deposited their nft, send the ETH to the contract
        if (!nftIsDeposited) {
            // The msg.value is automatically sent to the contract
            ethIsDeposited = true;        
        } else { 
            // If the lender has deposited their nft, send the ETH directly to the lender
            payable(lenderAddress).transfer(msg.value);
            // Transfer the NFT from the contract to the borrower
            nftCollection.safeTransferFrom(address(this), borrowerAddress, nftId);
            ethIsDeposited = true;
            emit RentalStarted();
            _beginRental();
        }
    }

    function withdrawNft() external payable {

        // Require that only the lender can withdraw the NFT
        require(msg.sender == lenderAddress, "The lender must be the msg sender");

        // Require that the NFT is in the contract and the ETH has not yet been deposited
        require(nftIsDeposited && !ethIsDeposited, "Either the NFT is not yet deposited or the ETH has already been deposited");

        // Send the nft back to the lender
        nftCollection.safeTransferFrom(address(this), lenderAddress, nftId);

    }

    function withdrawEth() external payable {

        // Require that only the borrower can call this function
        require(msg.sender == borrowerAddress, "The borrower must be the msg sender");

        // Require that the ETH has already been deposited and the NFT has not been
        require(!nftIsDeposited && ethIsDeposited, "Either the NFT is already deposited or the ETH is not yet deposited");

        // Have the contract send the eth back to the borrower
        payable(borrowerAddress).transfer(rentalPayment.add(collateral));

    }

    // This function can be called by anyone at anytime (if the nullification period elapses,
    // this will likely be called by whichever party has their assets deposited in the contract.)
    function nullifyContract() public payable {

        // Check if the rental has not started yet and the nullification period has passes
        if (rentalStartTime == 0 && block.timestamp >= nullificationTime) {

            // Check if ETH has already been deposited by the borrower
            if (ethIsDeposited) {
                // Have the contract return the ETH to the borrower
                payable(borrowerAddress).transfer(rentalPayment+collateral);
            }

            // Check if the NFT has already been deposited by the lender
            if (nftIsDeposited) {
                // Have the contract return the NFT to the lender
                nftCollection.safeTransferFrom(address(this), lenderAddress, nftId);
            }

            emit ContractNullified();
        }
    }

    // This function will be called by the borrower when they have returned the NFT to the contract
    function returnNft() external payable {

        // Check if the borrower has returned the NFT to the contract
        require(nftCollection.ownerOf(nftId) == address(this));

        // Check if the NFT has been returned on time
        if (block.timestamp <= dueDate) {
            // Return the NFT to the lender
            nftCollection.safeTransferFrom(address(this), lenderAddress, nftId);
            // Return the collateral to the borrower
            payable(borrowerAddress).transfer(collateral);
        }
        // Check if the NFT has been returned during the collateral payout period
        else if (block.timestamp > dueDate && block.timestamp < dueDate.add(collateralPayoutPeriod)) {
            // Return the NFT to the lender
            nftCollection.safeTransferFrom(address(this), lenderAddress, nftId);
            // Send the lender the collateral they are owed
            withdrawCollateral();
            // Send the borrower the collateral that is left
            payable(borrowerAddress).transfer(address(this).balance);
        }
    }

    // This function will likely be called by the lender but could be called by anyone.
    // It transfers to the lender the amount of collateral that is owed to them
    function withdrawCollateral() public payable {
        // This can only be called after the rental due date has passed and the payout period has begun
        require(block.timestamp > dueDate);

        // Calculate how much the lender should be able to withdraw
        uint256 withdrawableCollateral;
        uint256 timeLeftUntilFullyPaid = rentalStartTime + collateralPayoutPeriod - block.timestamp;
        if (timeLeftUntilFullyPaid > 0) {
            withdrawableCollateral = address(this).balance.sub(collateral.mul(timeLeftUntilFullyPaid.div(collateralPayoutPeriod)));
        } else {
            withdrawableCollateral = address(this).balance;
        }
        
        // Send the lender the collateral they're able to withdraw
        payable(lenderAddress).transfer(withdrawableCollateral);
    }

    /// -------------------------------------------- ///
    /// -------------- INTERNAL LOGIC -------------- ///
    /// -------------------------------------------- ///

    // This function is automatically called by the contract when the final required assets are deposited
    function _beginRental() private {
        rentalStartTime = block.timestamp;
        collateralLeft = collateral;
    }

    /// -------------------------------------------- ///
    /// ----------- ERC721 RECEIVER LOGIC ---------- ///
    /// -------------------------------------------- ///

    /// @notice Allows this contract to custody ERC721 Tokens
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        return IERC721TokenReceiver.onERC721Received.selector;
    }
}
