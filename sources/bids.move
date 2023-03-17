module token_objects_marketplace::bids {
    use std::signer;
    use std::error;
    use std::vector;
    use aptos_std::table_with_length::{Self, TableWithLength};
    use aptos_framework::coin::{Self, Coin};

    const E_BID_ALREADY: u64 = 1; 

    friend token_objects_marketplace::tradings;

    struct BidId has store, copy, drop {
        bidder_address: address,
        object_address: address,
        index: u64,
        bid_price: u64,
    }

    public fun bidder(bid_id: &BidId): address {
        bid_id.bidder_address
    }

    public fun object_address(bid_id: &BidId): address {
        bid_id.object_address
    }

    public fun bid_price(bid_id: &BidId): u64 {
        bid_id.bid_price
    }

    public fun index(bid_id: &BidId): u64 {
        bid_id.index
    }

    struct Bid<phantom TCoin> has store {
        coin: Coin<TCoin>,
        expiration_sec: u64
    }

    struct BidRecords<phantom TCoin> has key {
        key_list: vector<BidId>,
        bid_table: TableWithLength<BidId, Bid<TCoin>>
    }

    inline fun init_bid_records<TCoin>(bidder: &signer) {
        if (!exists<BidRecords<TCoin>>(signer::address_of(bidder))) {
            move_to(
                bidder,
                BidRecords<TCoin>{
                    key_list: vector::empty(),
                    bid_table: table_with_length::new()
                }
            )
        }
    }

    public(friend) fun bid<TCoin>(
        bidder: &signer,
        object_address: address,
        index: u64,
        bid_price: u64,
        expiration_sec: u64 // !!! range
    ): BidId
    acquires BidRecords {
        let bidder_address = signer::address_of(bidder);
        init_bid_records<TCoin>(bidder);
        let records = borrow_global_mut<BidRecords<TCoin>>(bidder_address);
        let bid_id = BidId {
            bidder_address,
            object_address,
            index,
            bid_price
        };
        assert!(
            !table_with_length::contains(&records.bid_table, bid_id),
            error::already_exists(E_BID_ALREADY)
        );
        
        let coin = coin::withdraw<TCoin>(bidder, bid_price);
        vector::push_back(&mut records.key_list, bid_id);
        table_with_length::add(
            &mut records.bid_table, 
            bid_id, Bid{
                coin,
                expiration_sec
            }
        );
        bid_id
    }
}