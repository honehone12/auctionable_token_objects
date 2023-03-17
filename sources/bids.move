module token_objects_marketplace::bids {

    struct BidId has store, copy, drop {
        bidder: address,
        object: address,
        index: u64,
        bid_price: u64,
    }

    public fun bidder(bid_id: &BidId): address {
        bid_id.bidder
    }

    public fun object_address(bid_id: &BidId): address {
        bid_id.object
    }

    public fun bid_price(bid_id: &BidId): u64 {
        bid_id.bid_price
    }

    public fun index(bid_id: &BidId): u64 {
        bid_id.index
    }

    
}