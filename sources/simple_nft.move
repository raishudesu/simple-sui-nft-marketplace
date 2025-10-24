// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// NFT Marketplace with minting, listing, and purchase functionality
module nft::sui_nft_marketplace {
    use sui::url::{Self, Url};
    use std::string;
    use sui::coin;
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};

    /// An NFT that can be minted, listed, and traded
    public struct PopChainNFT has key, store {
        id: UID,
        /// Name for the token
        name: string::String,
        /// Description of the token
        description: string::String,
        /// URL for the token image
        url: Url,
    }

    /// A listing resource that holds an NFT for sale
    public struct Listing has key {
        id: UID,
        /// The NFT being sold (stored directly in the listing)
        nft: PopChainNFT,
        /// Price in MIST (1 SUI = 1,000,000,000 MIST)
        price: u64,
        /// The seller's address
        seller: address,
    }

    /// Shared marketplace object to track all listings
    public struct Marketplace has key {
        id: UID,
        /// Balance to hold marketplace fees (optional)
        balance: Balance<SUI>,
    }

    // ===== Events =====

    public struct MintNFTEvent has copy, drop {
        object_id: ID,
        creator: address,
        name: string::String,
    }

    public struct ListNFTEvent has copy, drop {
        listing_id: ID,
        nft_id: ID,
        seller: address,
        price: u64,
    }

    public struct DelistNFTEvent has copy, drop {
        listing_id: ID,
        nft_id: ID,
    }

    public struct PurchaseNFTEvent has copy, drop {
        listing_id: ID,
        nft_id: ID,
        buyer: address,
        seller: address,
        price: u64,
    }

    // ===== Errors =====

    const EInvalidPrice: u64 = 0;
    const EInsufficientPayment: u64 = 1;
    const ENotSeller: u64 = 2;
    const ESelfPurchase: u64 = 3;

    // ===== Initialization =====

    /// Initialize the marketplace (call once during deployment)
    fun init(ctx: &mut TxContext) {
        let marketplace = Marketplace {
            id: object::new(ctx),
            balance: balance::zero(),
        };
        transfer::share_object(marketplace);
    }

    // ===== Entry Functions for External Interaction =====

    /// Mint a new NFT and transfer to sender (entry function for wallet/IDE interaction)
    entry fun mint_to_sender(
        name: vector<u8>,
        description: vector<u8>,
        url: vector<u8>,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let nft = PopChainNFT {
            id: object::new(ctx),
            name: string::utf8(name),
            description: string::utf8(description),
            url: url::new_unsafe_from_bytes(url)
        };
        
        sui::event::emit(MintNFTEvent {
            object_id: object::uid_to_inner(&nft.id),
            creator: sender,
            name: nft.name,
        });
        
        transfer::public_transfer(nft, sender);
    }

    /// Update NFT description (entry function)
    entry fun update_nft_description(
        nft: &mut PopChainNFT,
        new_description: vector<u8>,
    ) {
        nft.description = string::utf8(new_description)
    }

    /// Burn an NFT (entry function)
    entry fun burn_nft(nft: PopChainNFT) {
        let PopChainNFT { id, name: _, description: _, url: _ } = nft;
        object::delete(id)
    }

    /// List an NFT for sale (entry function)
    entry fun list_nft_for_sale(
        nft: PopChainNFT,
        price: u64,
        ctx: &mut TxContext
    ) {
        assert!(price > 0, EInvalidPrice);
        
        let nft_id = object::id(&nft);
        let seller = tx_context::sender(ctx);
        
        let listing = Listing {
            id: object::new(ctx),
            nft,
            price,
            seller,
        };
        
        let listing_id = object::id(&listing);
        
        sui::event::emit(ListNFTEvent {
            listing_id,
            nft_id,
            seller,
            price,
        });
        
        // Share the listing so anyone can purchase it
        transfer::share_object(listing);
    }

    /// Purchase a listed NFT (entry function)
    entry fun buy_nft(
        listing: Listing,
        mut payment: coin::Coin<SUI>,
        marketplace: &mut Marketplace,
        ctx: &mut TxContext
    ) {

         let Listing {
            id: listing_id,
            nft,
            price,
            seller,
        } = listing;
        
        let nft_id = object::id(&nft);

        let buyer = tx_context::sender(ctx);

        let payment_value = coin::value(&payment);
        assert!(payment_value >= price, EInsufficientPayment);

         // prevent self-buy
        assert!(buyer != seller, ESelfPurchase);
        
        // Calculate marketplace fee (2% fee)
        let fee_amount = price * 2 / 100;
        let seller_amount = price - fee_amount;
        
        // Split payment
        let fee_coin = coin::split(&mut payment, fee_amount, ctx);
        let seller_coin = coin::split(&mut payment, seller_amount, ctx);
        
        // Add fee to marketplace balance
        balance::join(&mut marketplace.balance, coin::into_balance(fee_coin));
        
        // Transfer payment to seller
        transfer::public_transfer(seller_coin, seller);
        
        // Return excess payment to buyer
        if (coin::value(&payment) > 0) {
            transfer::public_transfer(payment, buyer);
        } else {
            coin::destroy_zero(payment);
        };
        
        sui::event::emit(PurchaseNFTEvent {
            listing_id: object::uid_to_inner(&listing_id),
            nft_id,
            buyer,
            seller,
            price,
        });
        
        // Transfer NFT to buyer
        transfer::public_transfer(nft, buyer);
        
        object::delete(listing_id);
    }

    /// Delist an NFT (entry function)
    entry fun cancel_listing(
        listing: Listing,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == listing.seller, ENotSeller);
        
        let Listing {
            id: listing_id,
            nft,
            price: _,
            seller,
        } = listing;
        
        let nft_id = object::id(&nft);
        
        sui::event::emit(DelistNFTEvent {
            listing_id: object::uid_to_inner(&listing_id),
            nft_id,
        });
        
        // Return NFT to seller
        transfer::public_transfer(nft, seller);

        object::delete(listing_id);
    }

    // ===== Public Functions for Composability =====

    /// Mint a new NFT and return it (composable pattern)
    public fun mint(
        name: vector<u8>,
        description: vector<u8>,
        url: vector<u8>,
        ctx: &mut TxContext
    ): PopChainNFT {
        PopChainNFT {
            id: object::new(ctx),
            name: string::utf8(name),
            description: string::utf8(description),
            url: url::new_unsafe_from_bytes(url)
        }
    }

    /// Update the description of an NFT
    public fun update_description(
        nft: &mut PopChainNFT,
        new_description: vector<u8>,
    ) {
        nft.description = string::utf8(new_description)
    }

    /// Burn an NFT permanently
    public fun burn(nft: PopChainNFT) {
        let PopChainNFT { id, name: _, description: _, url: _ } = nft;
        object::delete(id)
    }

    /// List an NFT for sale at a specified price
    public fun list_nft(
        nft: PopChainNFT,
        price: u64,
        ctx: &mut TxContext
    ) {
        assert!(price > 0, EInvalidPrice);
        
        let nft_id = object::id(&nft);
        let seller = tx_context::sender(ctx);
        
        let listing = Listing {
            id: object::new(ctx),
            nft,
            price,
            seller,
        };
        
        let listing_id = object::id(&listing);
        
        sui::event::emit(ListNFTEvent {
            listing_id,
            nft_id,
            seller,
            price,
        });
        
        transfer::share_object(listing);
    }

    /// Delist an NFT
    public fun delist_nft(
        listing: Listing,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == listing.seller, ENotSeller);
        
        let Listing {
            id: listing_id,
            nft,
            price: _,
            seller,
        } = listing;
        
        let nft_id = object::id(&nft);
        
        sui::event::emit(DelistNFTEvent {
            listing_id: object::uid_to_inner(&listing_id),
            nft_id,
        });
        
        // Return NFT to seller
        transfer::public_transfer(nft, seller);
        
        object::delete(listing_id);
    }

    // ===== Getter Functions (View Functions) =====

    /// Get the NFT's name
    public fun name(nft: &PopChainNFT): &string::String {
        &nft.name
    }

    /// Get the NFT's description
    public fun description(nft: &PopChainNFT): &string::String {
        &nft.description
    }

    /// Get the NFT's URL
    public fun url(nft: &PopChainNFT): &Url {
        &nft.url
    }

    /// Get the NFT's ID
    public fun nft_id(nft: &PopChainNFT): ID {
        object::id(nft)
    }

    /// Get listing price
    public fun listing_price(listing: &Listing): u64 {
        listing.price
    }

    /// Get listing seller
    public fun listing_seller(listing: &Listing): address {
        listing.seller
    }

    /// Get listing NFT ID
    public fun listing_nft_id(listing: &Listing): ID {
        object::id(&listing.nft)
    }

    /// Get listing ID
    public fun listing_id(listing: &Listing): ID {
        object::id(listing)
    }

    /// Get marketplace balance
    public fun marketplace_balance(marketplace: &Marketplace): u64 {
        balance::value(&marketplace.balance)
    }

    // ===== Admin Functions =====

    /// Withdraw marketplace fees
    entry fun withdraw_marketplace_fees(
        marketplace: &mut Marketplace,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let withdrawn = coin::take(&mut marketplace.balance, amount, ctx);
        transfer::public_transfer(withdrawn, recipient);
    }
}

