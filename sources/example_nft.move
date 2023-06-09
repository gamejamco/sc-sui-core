module superfine::example_nft {
	use std::vector;
	use sui::object::{Self, ID, UID};
	use sui::tx_context::TxContext;
	use sui::transfer;
	use sui::event;

	struct ExampleNft has key, store {
		id: UID
	}

	struct EventNftsMinted has copy, drop {
		nft_ids: vector<ID>
	}

	public entry fun mint_nfts(
		recipient: address,
		quantity: u64,
		ctx: &mut TxContext
	): vector<ID> {
		let nft_ids = vector::empty<ID>();
		while (quantity > 0) {
			let nft = ExampleNft { id: object::new(ctx) };
			let nft_id = object::id(&nft);
			transfer::transfer(nft, recipient);
			vector::push_back(&mut nft_ids, nft_id);
			quantity = quantity - 1;
		};
		event::emit(EventNftsMinted { nft_ids });
		nft_ids
	}
}