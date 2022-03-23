// SPDX-License-Identifier: Apache 2

pragma solidity ^0.7.6;
pragma abicoder v2;

import './IWormhole.sol';
import './SwapHelper.sol';
import 'solidity-bytes-utils/contracts/BytesLib.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';


interface TokenBridge {
  function transferTokensWithPayload(
      address token,
      uint256 amount,
      uint16 recipientChain,
      bytes32 recipient,
      uint256 arbiterFee,
      uint32 nonce,
      bytes memory payload
    ) external payable returns (uint64);
    function completeTransferWithPayload(
        bytes memory encodedVm,
        address feeRecipient
    ) external returns (bytes memory);
}


interface IWETH is IERC20 {
    function withdraw(uint amount) external;
}


interface IUniswapRouter is ISwapRouter {
    function refundETH() external payable;
}


/// @title A cross-chain UniswapV3 example 
/// @notice Swaps against UniswapV3 pools and uses Wormhole TokenBridge
/// for cross-chain transfers
contract CrossChainSwapV3 {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;
    uint8 public immutable typeExactIn = 1;
    uint8 public immutable typeExactOut = 2;
    uint8 public immutable typeNativeSwap = 1;
    uint8 public immutable typeTokenSwap = 2;
    uint16 public immutable expectedVaaLength = 274;
    uint8 public immutable terraChainId = 3;
    IUniswapRouter public immutable swapRouter;
    address public immutable feeTokenAddress;
    address public immutable tokenBridgeAddress;
    address public immutable wrappedNative;

    constructor(
        address _swapRouterAddress, 
        address _feeTokenAddress, 
        address _tokenBridgeAddress,
        address _wrappedNativeAddress
    ) {
        swapRouter = IUniswapRouter(_swapRouterAddress);
        feeTokenAddress = _feeTokenAddress;
        tokenBridgeAddress = _tokenBridgeAddress;
        wrappedNative = _wrappedNativeAddress;
    }

    /// @dev Used to communicate information about executed swaps to UI/user
    event SwapResult(
        address indexed _recipient,
        address _tokenOut,
        address _from,
        uint256 _amountOut,
        uint8 _success
    );

    /// @dev Returns the parsed TokenBridge payload which contains swap 
    /// instructions after redeeming from the VAA from the TokenBridge
    function _getParsedPayload(
        bytes calldata encodedVaa,
        uint8 swapFunctionType,
        uint8 swapCurrencyType,
        address feeRecipient
    ) private returns (SwapHelper.DecodedVaaParameters memory payload) {
        // complete the transfer on the token bridge
        bytes memory vmPayload = TokenBridge(
            tokenBridgeAddress
        ).completeTransferWithPayload(encodedVaa, feeRecipient);

        // make sure payload is the right size
        require(
            vmPayload.length==expectedVaaLength, 
            "VAA has the wrong number of bytes"
        );

        // parse the payload 
        payload = SwapHelper.decodeVaaPayload(vmPayload);

        // sanity check payload parameters
        require(
            payload.swapFunctionType==swapFunctionType, 
            "incorrect swapFunctionType in payload"
        ); 
        require(
            payload.swapCurrencyType==swapCurrencyType, 
            "incorrect swapCurrencyType in payload"
        ); 
    }

    /// @dev Executes exactIn native asset swap and pays the relayer
    function recvAndSwapExactNativeIn(
        bytes calldata encodedVaa
    ) external returns (uint256 amountOut) {
        // check token balance before redeeming the payload
        (,bytes memory queriedBalanceBefore) = feeTokenAddress.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector,
            address(this)
        ));
        uint256 balanceBefore = abi.decode(queriedBalanceBefore, (uint256));

        SwapHelper.DecodedVaaParameters memory payload =
            _getParsedPayload(
                encodedVaa,
                typeExactIn,
                typeNativeSwap,
                msg.sender // feeRecipient
            );

        // query token balance after redeeming the payload
        (,bytes memory queriedBalanceAfter) = feeTokenAddress.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, 
            address(this)
        ));
        uint256 balanceAfter = abi.decode(queriedBalanceAfter, (uint256));

        // the balance change is the swap amount (less relayer fees)
        uint256 swapAmountLessFees = balanceAfter - balanceBefore;

        // sanity check path 
        require(
            payload.path[0]==feeTokenAddress, 
            "tokenIn must be UST"
        );
        require(
            payload.path[1]==wrappedNative, 
            "tokenOut must be wrapped Native"
        );

        // approve the router to spend tokens 
        TransferHelper.safeApprove(
            payload.path[0], 
            address(swapRouter), 
            swapAmountLessFees
        );
        
        // set swap options with user params
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: payload.path[0],
                tokenOut: payload.path[1],
                fee: payload.poolFee,
                recipient: address(this), 
                deadline: payload.deadline,
                amountIn: swapAmountLessFees,
                amountOutMinimum: payload.estimatedAmount,
                sqrtPriceLimitX96: 0
            });

        // try to execute the swap 
        try swapRouter.exactInputSingle(params) returns (uint256 amountOut) {
            // unwrap native and send to recipient 
            IWETH(wrappedNative).withdraw(amountOut);
            payable(payload.recipientAddress).transfer(amountOut);

            // used in UI to tell user they're getting
            // their desired token
            emit SwapResult(
                payload.recipientAddress, 
                payload.path[1], 
                msg.sender, 
                amountOut,
                1
            );
            return amountOut;
        } catch {
            // swap failed - return UST to recipient
            IERC20(feeTokenAddress).safeTransfer(
                payload.recipientAddress, 
                swapAmountLessFees
            );

            // used in UI to tell user they're getting
            // UST instead of their desired native asset
            emit SwapResult(
                payload.recipientAddress, 
                payload.path[0], 
                msg.sender, 
                swapAmountLessFees,
                0
            );
        }
    }

    /// @dev Executes exactIn token swap and pays the relayer
    function recvAndSwapExactIn(
        bytes calldata encodedVaa
    ) external returns (uint256 amountOut) {
        // check token balance before redeeming the payload
        (,bytes memory queriedBalanceBefore) = feeTokenAddress.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector,
            address(this)
        ));
        uint256 balanceBefore = abi.decode(queriedBalanceBefore, (uint256));

        // redeem and fetch the parsed payload
        SwapHelper.DecodedVaaParameters memory payload =
            _getParsedPayload(
                encodedVaa,
                typeExactIn,
                typeTokenSwap,
                msg.sender // feeRecipient
            );

        // query token balance after redeeming the payload
        (,bytes memory queriedBalanceAfter) = feeTokenAddress.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, 
            address(this)
        ));
        uint256 balanceAfter = abi.decode(queriedBalanceAfter, (uint256));

        // the balance change is the swap amount (less relayer fees)
        uint256 swapAmountLessFees = balanceAfter - balanceBefore;

        // check path to see if first element is the feeToken
        require(payload.path[0]==feeTokenAddress, "tokenIn must be UST");

        // approve the router to spend tokens
        TransferHelper.safeApprove(
            payload.path[0], 
            address(swapRouter), 
            swapAmountLessFees
        );
        
        // set swap options with user params
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: payload.path[0],
                tokenOut: payload.path[1],
                fee: payload.poolFee,
                recipient: payload.recipientAddress,
                deadline: payload.deadline,
                amountIn: swapAmountLessFees,
                amountOutMinimum: payload.estimatedAmount,
                sqrtPriceLimitX96: 0
            });

        // try to perform the swap
        try swapRouter.exactInputSingle(params) returns (uint256 amountOut) {
            // used in UI to tell user they're getting
            // their desired token
            emit SwapResult(
                payload.recipientAddress, 
                payload.path[1], 
                msg.sender, 
                amountOut,
                1
            );
            return amountOut;
        } catch {
            // swap failed - return UST to recipient
            IERC20(feeTokenAddress).safeTransfer(
                payload.recipientAddress, 
                swapAmountLessFees
            );

            // used in UI to tell user they're getting
            // UST instead of their desired token
            emit SwapResult(
                payload.recipientAddress, 
                payload.path[0], 
                msg.sender, 
                swapAmountLessFees,
                0
            );
        }
    }

    /// @dev Executes exactIn native asset and token swaps before
    /// sending a custom payload to the TokenBridge
    function _swapExactInBeforeTransfer(
        uint256 amountIn,
        uint256 amountOutMinimum, 
        address contractCaller,
        address[] calldata path,
        uint256 deadline,
        uint24 poolFee,
        uint8 swapType
    ) internal returns (uint256 amountOut) {
        if (swapType == typeTokenSwap) {
            // transfer the allowed amount of tokens to this contract
            IERC20 token = IERC20(path[0]);
            token.safeTransferFrom(contractCaller, address(this), amountIn);

            // approve the router to spend tokens
            TransferHelper.safeApprove(
                path[0], 
                address(swapRouter), 
                amountIn
            );
        }

        // set swap options with user params
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: path[0],
                tokenOut: path[1],
                fee: poolFee,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn, 
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            });

        // perform the swap
        if (swapType == typeTokenSwap) {
            amountOut = swapRouter.exactInputSingle(params);
        } else { // native swap
            amountOut = swapRouter.exactInputSingle{value: amountIn}(params);
        }
    }

    /// @dev Calls _swapExactInBeforeTransfer and encodes custom payload with 
    /// instructions for executing token swaps on the destination chain
    function swapExactInAndTransfer(
        SwapHelper.ExactInParameters calldata swapParams,
        address[] calldata path,
        uint256 relayerFee,
        uint16 targetChainId,
        bytes32 targetContractAddress,
        uint32 nonce
    ) external {  
        require(
            swapParams.amountOutMinimum > relayerFee, 
            "insufficient amountOutMinimum to pay relayer"
        );
        require(
            path[1]==feeTokenAddress, 
            "tokenOut must be UST for first swap"
        );  

        // peform the first swap
        uint256 amountOut = _swapExactInBeforeTransfer(
            swapParams.amountIn, 
            swapParams.amountOutMinimum, 
            msg.sender,
            path[0:2], 
            swapParams.deadline,
            swapParams.poolFee,
            typeTokenSwap
        );

        // encode payload for second swap
        bytes memory payload = abi.encodePacked(
            swapParams.targetAmountOutMinimum,
            swapParams.targetChainRecipient,
            path[2],
            path[3],
            swapParams.deadline,
            swapParams.poolFee,
            typeExactIn,
            typeTokenSwap
        );

        // approve token bridge to spend feeTokens (UST)
        TransferHelper.safeApprove(
            feeTokenAddress, 
            tokenBridgeAddress, 
            amountOut
        );

        // send transfer with payload to the TokenBridge
        TokenBridge(tokenBridgeAddress).transferTokensWithPayload(
            feeTokenAddress, 
            amountOut, 
            targetChainId, 
            targetContractAddress, 
            relayerFee, 
            nonce, 
            payload
        );
    }  

    /// @dev Calls _swapExactInBeforeTransfer and encodes custom payload with 
    /// instructions for executing native asset swaps on the destination chain
    function swapExactNativeInAndTransfer(
        SwapHelper.ExactInParameters calldata swapParams,
        address[] calldata path,
        uint256 relayerFee,
        uint16 targetChainId,
        bytes32 targetContractAddress,
        uint32 nonce
    ) external payable {  
        require(
            swapParams.amountOutMinimum > relayerFee, 
            "insufficient amountOutMinimum to pay relayer"
        );
        require(
            path[0]==wrappedNative, 
            "tokenIn must be wrapped native asset for first swap"
        );
        require(
            path[1]==feeTokenAddress, 
            "tokenOut must be UST for first swap"
        ); 
        require(msg.value > 0, "must pass non 0 native asset amount");

        // peform the first swap
        uint256 amountOut = _swapExactInBeforeTransfer(
            msg.value,
            swapParams.amountOutMinimum, 
            msg.sender,
            path[0:2], 
            swapParams.deadline,
            swapParams.poolFee,
            typeNativeSwap
        );

        // create payload variable
        bytes memory payload;

        // UST is native to Terra - no need for swap instructions
        if (targetChainId == terraChainId) { 
            payload = abi.encodePacked(
                swapParams.targetChainRecipient
            );
        } else {  
            payload = abi.encodePacked(
                swapParams.targetAmountOutMinimum,
                swapParams.targetChainRecipient,
                path[2],
                path[3],
                swapParams.deadline,
                swapParams.poolFee,
                typeExactIn,
                typeNativeSwap
            );  
        }

        // approve token bridge to spend feeTokens (UST)
        TransferHelper.safeApprove(
            feeTokenAddress, 
            tokenBridgeAddress, 
            amountOut
        );

        // send transfer with payload to the TokenBridge
        TokenBridge(tokenBridgeAddress).transferTokensWithPayload(
            feeTokenAddress, 
            amountOut, 
            targetChainId, 
            targetContractAddress, 
            relayerFee, 
            nonce, 
            payload
        );
    }

    /// @dev Executes exactOut native asset swap and pays the relayer
    function recvAndSwapExactNativeOut(
        bytes calldata encodedVaa
    ) external returns (uint256 amountInUsed) {
        // check token balance before redeeming the payload
        (,bytes memory queriedBalanceBefore) = feeTokenAddress.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector,
            address(this)
        ));
        uint256 balanceBefore = abi.decode(queriedBalanceBefore, (uint256));

        // redeem and fetch parsed payload
        SwapHelper.DecodedVaaParameters memory payload =
            _getParsedPayload(
                encodedVaa,
                typeExactOut,
                typeNativeSwap,
                msg.sender // feeRecipient
            );

        // query token balance after redeeming the payload
        (,bytes memory queriedBalanceAfter) = feeTokenAddress.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, 
            address(this)
        ));
        uint256 balanceAfter = abi.decode(queriedBalanceAfter, (uint256));

        // the balance change is the swap amount (less relayer fees)
        uint256 maxAmountInLessFees = balanceAfter - balanceBefore;

        // sanity check path
        require(
            payload.path[0]==feeTokenAddress, 
            "tokenIn must be UST"
        );
        require(
            payload.path[1]==wrappedNative, 
            "tokenOut must be wrapped native asset"
        );

        // amountOut is the estimated swap amount for exact out methods
        uint256 amountOut = payload.estimatedAmount;

        // approve the router to spend tokens
        TransferHelper.safeApprove(
            payload.path[0], 
            address(swapRouter), 
            maxAmountInLessFees
        ); 

        // set swap options with user params
        ISwapRouter.ExactOutputSingleParams memory params =
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: payload.path[0],
                tokenOut: payload.path[1],
                fee: payload.poolFee,
                recipient: address(this), 
                deadline: payload.deadline,
                amountOut: amountOut,
                amountInMaximum: maxAmountInLessFees, 
                sqrtPriceLimitX96: 0
            });

        // try to perform the swap
        try swapRouter.exactOutputSingle(params) returns (uint256 amountInUsed) {
            // refund recipient with any UST not used in the swap
            if (amountInUsed < maxAmountInLessFees) {
                TransferHelper.safeApprove(
                    feeTokenAddress, 
                    address(swapRouter), 
                    0
                );
                IERC20(feeTokenAddress).safeTransfer(
                    payload.recipientAddress, 
                    maxAmountInLessFees - amountInUsed
                );  
            }

            // unwrap native and send to recipient 
            IWETH(wrappedNative).withdraw(amountOut);
            payable(payload.recipientAddress).transfer(amountOut);

            // used in UI to tell user they're getting
            // their desired native asset
            emit SwapResult(
                payload.recipientAddress, 
                payload.path[1], 
                msg.sender, 
                amountOut,
                1
            );
            return amountInUsed;
        } catch {
            // swap failed - return UST to recipient
            IERC20(feeTokenAddress).safeTransfer(
                payload.recipientAddress, 
                maxAmountInLessFees
            );

            // used in UI to tell user they're getting
            // UST instead of their desired native asset
            emit SwapResult(
                payload.recipientAddress, 
                payload.path[0], 
                msg.sender, 
                maxAmountInLessFees,
                0
            );
        }
    }

    /// @dev Executes exactOut token swap and pays the relayer
    function recvAndSwapExactOut(
        bytes calldata encodedVaa
    ) external returns (uint256 amountInUsed) {
        // check token balance before redeeming the payload
        (,bytes memory queriedBalanceBefore) = feeTokenAddress.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector,
            address(this)
        ));
        uint256 balanceBefore = abi.decode(queriedBalanceBefore, (uint256));

        // redeem and fetch parsed payload
        SwapHelper.DecodedVaaParameters memory payload =
            _getParsedPayload(
                encodedVaa,
                typeExactOut,
                typeTokenSwap,
                msg.sender // feeRecipient
            );

        // query token balance after redeeming the payload
        (,bytes memory queriedBalanceAfter) = feeTokenAddress.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, 
            address(this)
        ));
        uint256 balanceAfter = abi.decode(queriedBalanceAfter, (uint256));

        // the balance change is the swap amount (less relayer fees)
        uint256 maxAmountInLessFees = balanceAfter - balanceBefore;
        
        // check path to see if first element is the feeToken
        require(payload.path[0]==feeTokenAddress, "tokenIn must be UST");

        // amountOut is the estimated swap amount for exact out methods
        uint256 amountOut = payload.estimatedAmount;

        // approve the router to spend tokens
        TransferHelper.safeApprove(
            payload.path[0], 
            address(swapRouter), 
            maxAmountInLessFees
        ); 

        // set swap options with user params
        ISwapRouter.ExactOutputSingleParams memory params =
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: payload.path[0],
                tokenOut: payload.path[1],
                fee: payload.poolFee,
                recipient: payload.recipientAddress,
                deadline: payload.deadline,
                amountOut: amountOut,
                amountInMaximum: maxAmountInLessFees, 
                sqrtPriceLimitX96: 0
            });

        // try to perform the swap
        try swapRouter.exactOutputSingle(params) returns (uint256 amountInUsed) {
            // refund recipient with any UST not used in the swap
            if (amountInUsed < maxAmountInLessFees) {
                TransferHelper.safeApprove(
                    feeTokenAddress, 
                    address(swapRouter), 
                    0
                );
                IERC20(feeTokenAddress).safeTransfer(
                    payload.recipientAddress, 
                    maxAmountInLessFees - amountInUsed
                );  
            }

            // used in UI to tell user they're getting
            // their desired token
            emit SwapResult(
                payload.recipientAddress, 
                payload.path[1], 
                msg.sender, 
                amountOut,
                1
            );
            return amountInUsed;
        } catch {
            // swap failed - return UST to recipient
            IERC20(feeTokenAddress).safeTransfer(
                payload.recipientAddress, 
                maxAmountInLessFees
            );

            // used in UI to tell user they're getting
            // UST instead of their desired token
            emit SwapResult(
                payload.recipientAddress, 
                payload.path[0], 
                msg.sender, 
                maxAmountInLessFees,
                0
            );
        }
    }

    /// @dev Executes exactOut native asset and token swaps before
    /// sending a custom payload to the TokenBridge
    function _swapExactOutBeforeTransfer(
        uint256 amountOut, 
        uint256 amountInMaximum,
        address contractCaller,
        address[] calldata path,
        uint256 deadline,
        uint24 poolFee,
        uint8 swapType
    ) internal {
        // create instance of erc20 token for token swaps
        IERC20 token = IERC20(path[0]);

        if (swapType == typeTokenSwap) {
            // transfer tokens to this contract
            token.safeTransferFrom(
                contractCaller, 
                address(this), 
                amountInMaximum
            );

            // approve the router to spend tokens
            TransferHelper.safeApprove(
                path[0], 
                address(swapRouter), 
                amountInMaximum
            );
        }

        // set swap options with user params
        ISwapRouter.ExactOutputSingleParams memory params =
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: path[0],
                tokenOut: path[1],
                fee: poolFee,
                recipient: address(this),
                deadline: deadline,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: 0
            });

        if (swapType == typeTokenSwap) {
            // executes the swap returning the amountInUsed
            uint256 amountInUsed = swapRouter.exactOutputSingle(params);

            // return any amountIn not used in the swap to contractCaller
            if (amountInUsed < amountInMaximum) {
                TransferHelper.safeApprove(path[0], address(swapRouter), 0);
                token.safeTransfer(
                    contractCaller, 
                    amountInMaximum - amountInUsed
                );
            }
        } else { // native swap 
            // executes the swap returning the amountInUsed 
            // ask for our money back -_- after the swap executes        
            uint256 amountInUsed = swapRouter.exactOutputSingle{value: amountInMaximum}(params);
            swapRouter.refundETH();

            // return unused native asset to contractCaller
            if (amountInUsed < amountInMaximum) {
                TransferHelper.safeApprove(path[0], address(swapRouter), 0);
                payable(contractCaller).transfer(
                    amountInMaximum - amountInUsed
                );
            }
        }
    }

    /// @dev Calls _swapExactOutBeforeTransfer and encodes custom payload with 
    /// instructions for executing token swaps on the destination chain
    function swapExactOutAndTransfer(
        SwapHelper.ExactOutParameters calldata swapParams,
        address[] calldata path,
        uint256 relayerFee,
        uint16 targetChainId, 
        bytes32 targetContractAddress,
        uint32 nonce
    ) external {  
        require(
            swapParams.amountOut > relayerFee, 
            "insufficient amountOut to pay relayer"
        );
        require(
            path[1]==feeTokenAddress, 
            "tokenOut must be UST for first swap"
        );

        // peform the first swap
        _swapExactOutBeforeTransfer(
            swapParams.amountOut, 
            swapParams.amountInMaximum, 
            msg.sender,
            path[0:2], 
            swapParams.deadline,
            swapParams.poolFee,
            typeTokenSwap
        );

        // encode payload for second swap
        bytes memory payload = abi.encodePacked(
            swapParams.targetAmountOut,
            swapParams.targetChainRecipient,
            path[2],
            path[3],
            swapParams.deadline,
            swapParams.poolFee,
            typeExactOut,
            typeTokenSwap
        );

        // approve token bridge to spend feeTokens (UST)
        TransferHelper.safeApprove(
            feeTokenAddress, 
            tokenBridgeAddress, 
            swapParams.amountOut
        );

        // send transfer with payload to the TokenBridge
        TokenBridge(tokenBridgeAddress).transferTokensWithPayload(
            feeTokenAddress, 
            swapParams.amountOut, 
            targetChainId, 
            targetContractAddress, 
            relayerFee, 
            nonce, 
            payload
        );
    }

    /// @dev Calls _swapExactOutBeforeTransfer and encodes custom payload with 
    /// instructions for executing native asset swaps on the destination chain
    function swapExactNativeOutAndTransfer(
        SwapHelper.ExactOutParameters calldata swapParams,
        address[] calldata path,
        uint256 relayerFee,
        uint16 targetChainId,
        bytes32 targetContractAddress,
        uint32 nonce
    ) external payable {  
        require(
            swapParams.amountOut > relayerFee, 
            "insufficient amountOut to pay relayer"
        );
        require(
            path[0]==wrappedNative, 
            "tokenIn must be wrapped native asset for first swap"
        );
        require(
            path[1]==feeTokenAddress, 
            "tokenOut must be UST for first swap"
        );
        require(msg.value > 0, "must pass non 0 native asset amount");

        // peform the first swap
        _swapExactOutBeforeTransfer(
            swapParams.amountOut, 
            msg.value, 
            msg.sender,
            path[0:2], 
            swapParams.deadline,
            swapParams.poolFee,
            typeNativeSwap
        );

        // create payload variable
        bytes memory payload;

        // UST is native to Terra - no need for swap instructions
        if (targetChainId == terraChainId) { 
            payload = abi.encodePacked(
                swapParams.targetChainRecipient
            );
        } else {  
            payload = abi.encodePacked(
                swapParams.targetAmountOut,
                swapParams.targetChainRecipient,
                path[2],
                path[3],
                swapParams.deadline,
                swapParams.poolFee,
                typeExactOut,
                typeNativeSwap
            );  
        }

        // approve token bridge to spend feeTokens (UST)
        TransferHelper.safeApprove(
            feeTokenAddress, 
            tokenBridgeAddress, 
            swapParams.amountOut
        );

        // send transfer with payload to the TokenBridge
        TokenBridge(tokenBridgeAddress).transferTokensWithPayload(
            feeTokenAddress, 
            swapParams.amountOut, 
            targetChainId, 
            targetContractAddress, 
            relayerFee, 
            nonce, 
            payload
        );
    }

    // necessary for receiving native assets 
    receive() external payable {}
}