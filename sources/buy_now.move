module space_powder_marketplace::buy_now {
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::token::{Self, Token, TokenId};
    use aptos_framework::table::{Self, Table};
    use std::event::{Self, EventHandle};
    use std::signer;
    use std::option::{Self, Option};

    const E_INVALID_BUYER: u64 = 0;
    const E_INSUFFICIENT_FUNDS: u64 = 1;

    struct ListedItem has store {
        price: u64,
        locked_token: Option<Token>,
    }
    
    // Set of data sent to the event stream during a listing of a token (for fixed price)
    struct ListEvent has drop, store {
        id: TokenId,
        amount: u64,
    }

    // Set of data sent to the event stream during a buying of a token (for fixed price)
    struct BuyEvent has drop, store {
        id: TokenId,
    }

    // Set of data sent to the event stream during a delisting of a token (for fixed price)
    struct DelistEvent has drop, store {
        id: TokenId,
    }

    struct ListedItemsData has key {
        listed_items: Table<TokenId, ListedItem>,
        listing_events: EventHandle<ListEvent>,
        buying_events: EventHandle<BuyEvent>,
        delisting_events: EventHandle<DelistEvent>,
    }

    public fun init_marketplace(seller: &signer) {
        move_to(seller, ListedItemsData {
            listed_items: table::new<TokenId, ListedItem>(),
            listing_events: event::new_event_handle<ListEvent>(seller),
            buying_events: event::new_event_handle<BuyEvent>(seller),
            delisting_events: event::new_event_handle<DelistEvent>(seller),
        });
    }

    public entry fun list_token(seller: &signer, collection_owner_addres: address, collection_name: vector<u8>, token_name: vector<u8>, price: u64) acquires ListedItemsData {
        let token_id = token::create_token_id_raw(collection_owner_addres, collection_name, token_name);
        let seller_addr = signer::address_of(seller);

        if (!exists<ListedItemsData>(seller_addr)) {
            init_marketplace(seller);
        };

        let token = token::withdraw_token(seller, token_id, 1);

        let listed_items_data = borrow_global_mut<ListedItemsData>(seller_addr);
        let listed_items = &mut listed_items_data.listed_items;

        event::emit_event<ListEvent>(
            &mut listed_items_data.listing_events,
            ListEvent { id: token_id, amount: price },
        );

        table::add(listed_items, token_id, ListedItem {
            price,
            locked_token: option::some(token),
        })
    }

    public entry fun buy_token(buyer: &signer, seller_addr: address, collection_owner_addres: address, collection_name: vector<u8>, token_name: vector<u8>) acquires ListedItemsData {
        let token_id = token::create_token_id_raw(collection_owner_addres, collection_name, token_name);
        let buyer_addr = signer::address_of(buyer);
        assert!(buyer_addr != seller_addr, E_INVALID_BUYER);

        let listedItemsData = borrow_global_mut<ListedItemsData>(seller_addr);

        let listed_items = &mut listedItemsData.listed_items;
        let listed_item = table::borrow_mut(listed_items, token_id);

        assert!(coin::balance<AptosCoin>(buyer_addr) >= listed_item.price, E_INSUFFICIENT_FUNDS);
        coin::transfer<AptosCoin>(buyer, seller_addr, listed_item.price);

        // This is a copy of locked_token
        let locked_token: &mut Option<Token> = &mut listed_item.locked_token;

        // Move to new owner
        let token = option::extract(locked_token);
        token::deposit_token(buyer, token);

        // Remove token from escrow and destroy entry
        let ListedItem{price: _, locked_token: remove_empty_option} = table::remove(listed_items, token_id);
        option::destroy_none(remove_empty_option);

        event::emit_event<BuyEvent>(
            &mut listedItemsData.buying_events,
            BuyEvent { id: token_id },
        );
    }

    public entry fun delist_token(seller: &signer, collection_owner_addres: address, collection_name: vector<u8>, token_name: vector<u8>) acquires ListedItemsData {
        let token_id = token::create_token_id_raw(collection_owner_addres, collection_name, token_name);
        let seller_addr = signer::address_of(seller);
        
        let listedItemsData = borrow_global_mut<ListedItemsData>(seller_addr);
        let listed_items = &mut listedItemsData.listed_items;
        let listed_item = table::borrow_mut(listed_items, token_id);
        // This is a copy of locked_token
        let locked_token: &mut Option<Token> = &mut listed_item.locked_token;

        // Move to seller
        let token = option::extract(locked_token);
        token::deposit_token(seller, token);

        // Remove token from escrow and destroy entry
        let ListedItem{price: _, locked_token: remove_empty_option} = table::remove(listed_items, token_id);
        option::destroy_none(remove_empty_option);

        event::emit_event<DelistEvent>(
            &mut listedItemsData.delisting_events,
            DelistEvent { id: token_id },
        );
    }  
    
    /**************************** TESTS ****************************/
    #[test_only]
    use aptos_framework::token_transfers::{Self};
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use std::string;
    #[test_only]
    const E_INCORRECT_TOKEN_OWNER: u64 = 100;
    #[test_only]
    const E_INVALID_BALANCE: u64 = 101;
    #[test_only]
    public fun create_collection_and_token(
        collection_creator: &signer,
        collection_name: vector<u8>,
        token_name: vector<u8>,
        token_amount: u64,
        collection_max: u64,
        token_max: u64,
    ): TokenId {
        token::create_collection(
            collection_creator,
            string::utf8(collection_name),
            string::utf8(b"Any collection description"),
            string::utf8(b"https://anyuri.com"),
            option::some(collection_max),
        );
        token::create_token(
            collection_creator,
            string::utf8(collection_name),
            string::utf8(token_name),
            string::utf8(b"Any token description"),
            true,
            token_amount,
            option::some(token_max),
            string::utf8(b"https://anyuri.com"),
            0,
        )
    }
    #[test_only]
    public fun before_each_setup(
        collection_creator: &signer,
        collection_name: vector<u8>,
        token_name: vector<u8>,
        seller: &signer,
    ) {
        // Create a collection owned by collection_creator
        let collection_creator_addr = signer::address_of(collection_creator);
        let token_id = create_collection_and_token(collection_creator, collection_name, token_name, 1, 2, 1);
        // Change ownership of collection's token(NFT) to seller
        let seller_addr = signer::address_of(seller);
        token_transfers::offer(collection_creator, seller_addr, token_id, 1);
        token_transfers::claim(seller, collection_creator_addr, token_id);
            // Verify seller is owner of token(NFT)
            assert!(token::balance_of(collection_creator_addr, token_id) == 0, E_INCORRECT_TOKEN_OWNER);
            assert!(token::balance_of(seller_addr, token_id) == 1, E_INCORRECT_TOKEN_OWNER);
    }
    #[test(faucet = @0x1, seller = @0x2, buyer = @0x3, collection_creator = @0x4)]
    public fun WHEN_list_and_buy_THEN_succeeds_buy(faucet: signer, seller: signer, buyer: signer, collection_creator: signer) acquires ListedItemsData {
        // Setup
        let collection_name: vector<u8> = b"Any collection name";
        let token_name: vector<u8> = b"Any token name";
        before_each_setup(&collection_creator, collection_name, token_name, &seller);
        managed_coin::initialize<AptosCoin>(&faucet, b"AptosCoin", b"TEST", 6, false);
        managed_coin::register<AptosCoin>(&faucet);
        managed_coin::register<AptosCoin>(&seller);
        managed_coin::register<AptosCoin>(&buyer);
        // List collection for sale
        let seller_addr = signer::address_of(&seller);
        let collection_creator_addr = signer::address_of(&collection_creator);
        let token_id = token::create_token_id_raw(collection_creator_addr, collection_name, token_name);
        let token_price = 100;
        list_token(&seller, collection_creator_addr, collection_name, token_name, token_price);
        {
            // Verify listed_items(escrow) entry was created
            let listedItemsData = borrow_global_mut<ListedItemsData>(seller_addr);
            let listed_items = &mut listedItemsData.listed_items;
            assert!(table::length(listed_items) == 1, E_INCORRECT_TOKEN_OWNER);
            // Verify seller doesn't own the token(NFT) anymore
            assert!(token::balance_of(seller_addr, token_id) == 0, E_INCORRECT_TOKEN_OWNER);
        };
        // Create and fund faucet        
        let coin_mint_amount = 1000;
        let faucet_addr = signer::address_of(&faucet);
        managed_coin::mint<AptosCoin>(&faucet, faucet_addr, coin_mint_amount);
        // Fund buyer
        let buyer_addr = signer::address_of(&buyer);
        coin::transfer<AptosCoin>(&faucet, buyer_addr, token_price);
            // Verify buyer insuffice_funds amount of coins
            assert!(coin::balance<AptosCoin>(buyer_addr) == token_price, E_INVALID_BALANCE);
        
        // Buy token(NFT)
        buy_token(&buyer, seller_addr, collection_creator_addr, collection_name, token_name);
            // Verify buyer owns token(NFT) and seller has the coins
            assert!(token::balance_of(seller_addr, token_id) == 0, E_INCORRECT_TOKEN_OWNER);
            assert!(token::balance_of(buyer_addr, token_id) == 1, E_INCORRECT_TOKEN_OWNER);
            assert!(coin::balance<AptosCoin>(seller_addr) == token_price, E_INVALID_BALANCE);
            assert!(coin::balance<AptosCoin>(buyer_addr) == 0, E_INVALID_BALANCE);
    }
    #[expected_failure(abort_code = 1)]
    #[test(faucet = @0x1, seller = @0x2, buyer = @0x3, collection_creator = @0x4)]
    public fun WHEN_insuffiencient_funds_THEN_fails_buy(faucet: signer, seller: signer, buyer: signer, collection_creator: signer) acquires ListedItemsData {
        // Setup
        let collection_name: vector<u8> = b"Any collection name";
        let token_name: vector<u8> = b"Any token name";
        before_each_setup(&collection_creator, collection_name, token_name, &seller);
        managed_coin::initialize<AptosCoin>(&faucet, b"AptosCoin", b"TEST", 6, false);
        managed_coin::register<AptosCoin>(&faucet);
        managed_coin::register<AptosCoin>(&seller);
        managed_coin::register<AptosCoin>(&buyer);
        // List collection for sale
        let seller_addr = signer::address_of(&seller);
        let collection_creator_addr = signer::address_of(&collection_creator);
        let token_id = token::create_token_id_raw(collection_creator_addr, collection_name, token_name);
        let token_price = 100;
        list_token(&seller, collection_creator_addr, collection_name, token_name, token_price);
        {
            // Verify listed_items(escrow) entry was created
            let listedItemsData = borrow_global_mut<ListedItemsData>(seller_addr);
            let listed_items = &mut listedItemsData.listed_items;
            assert!(table::length(listed_items) == 1, E_INCORRECT_TOKEN_OWNER);
            // Verify seller doesn't own the token(NFT) anymore
            assert!(token::balance_of(seller_addr, token_id) == 0, E_INCORRECT_TOKEN_OWNER);
        };
        // Create and fund faucet        
        let coin_mint_amount = 1000;
        let faucet_addr = signer::address_of(&faucet);
        managed_coin::mint<AptosCoin>(&faucet, faucet_addr, coin_mint_amount);
        // Fund buyer
        let buyer_addr = signer::address_of(&buyer);
        let deficit_from_token_price = 10;
        let insufficient_funds = token_price - deficit_from_token_price;
        coin::transfer<AptosCoin>(&faucet, buyer_addr, insufficient_funds);
        {
            // Verify listed_items(escrow) entry still has token(NFT)
            let listedItemsData = borrow_global_mut<ListedItemsData>(seller_addr);
            let listed_items = &mut listedItemsData.listed_items;
            assert!(table::length(listed_items) == 1, E_INCORRECT_TOKEN_OWNER);
            // Verify buyer insuffice_funds amount of coins
            assert!(coin::balance<AptosCoin>(buyer_addr) == insufficient_funds, E_INVALID_BALANCE);
        };
        
        buy_token(&buyer, seller_addr, collection_creator_addr, collection_name, token_name);
            // Verify buyer owns token(NFT) and seller has the coins
            assert!(token::balance_of(buyer_addr, token_id) == 0, E_INCORRECT_TOKEN_OWNER);
            assert!(coin::balance<AptosCoin>(seller_addr) == 0, E_INVALID_BALANCE);
            assert!(coin::balance<AptosCoin>(buyer_addr) == insufficient_funds, E_INVALID_BALANCE);
    }
    #[test(faucet = @0x1, seller = @0x2, buyer = @0x3, collection_creator = @0x4)]
    public fun WHEN_seller_delist_THEN_succeeds_delist(faucet: signer, seller: signer, buyer: signer, collection_creator: signer) acquires ListedItemsData {
        // Setup
        let collection_name: vector<u8> = b"Any collection name";
        let token_name: vector<u8> = b"Any token name";
        before_each_setup(&collection_creator, collection_name, token_name, &seller);
        managed_coin::initialize<AptosCoin>(&faucet, b"AptosCoin", b"TEST", 6, false);
        managed_coin::register<AptosCoin>(&faucet);
        managed_coin::register<AptosCoin>(&seller);
        managed_coin::register<AptosCoin>(&buyer);
        // List collection for sale
        let seller_addr = signer::address_of(&seller);
        let collection_creator_addr = signer::address_of(&collection_creator);
        let token_id = token::create_token_id_raw(collection_creator_addr, collection_name, token_name);
        let token_price = 100;
        list_token(&seller, collection_creator_addr, collection_name, token_name, token_price);            
        {
            // Verify listed_items(escrow) entry was created
            let listedItemsData = borrow_global_mut<ListedItemsData>(seller_addr);
            let listed_items = &mut listedItemsData.listed_items;
            assert!(table::length(listed_items) == 1, E_INCORRECT_TOKEN_OWNER);
            // Verify seller doesn't own the token(NFT) anymore
            assert!(token::balance_of(seller_addr, token_id) == 0, E_INCORRECT_TOKEN_OWNER);
        };
        // Delist listed token(NFT)
        delist_token(&seller, collection_creator_addr, collection_name, token_name);
        {
            // Verify listed_items(escrow) entry was removed
            let listedItemsData = borrow_global_mut<ListedItemsData>(seller_addr);
            let listed_items = &mut listedItemsData.listed_items;
            assert!(table::length(listed_items) == 0, E_INCORRECT_TOKEN_OWNER);
            // Verify seller owns the token(NFT) anymore 
            assert!(token::balance_of(seller_addr, token_id) == 1, E_INCORRECT_TOKEN_OWNER);
            assert!(token::balance_of(seller_addr, token_id) == 1, E_INCORRECT_TOKEN_OWNER);
        };
    }
}