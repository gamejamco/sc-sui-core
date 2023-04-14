module superfine::superfine_claim {
	use std::vector;
	use std::bcs;
	use sui::object::{Self, ID, UID};
	use sui::transfer;
	use sui::tx_context::{Self, TxContext};
	use sui::dynamic_object_field as dof;
	use sui::ed25519;
	use sui::hash;
	use sui::vec_set::{Self, VecSet};
	use superfine::utils;

	const ENotAssetOwner: u64 = 135289670000;
	const ENotCampaignCreator: u64 = 135289670000 + 1;
	const EInvalidSignature: u64 =  135289670000 + 2;
	const ENotAdmin: u64 = 135289670000 + 3;
	const ENotOperator: u64 = 135289670000 + 4;

	struct ClaimingPlatform has key {
		id: UID,
		admin: address,
		operators: VecSet<address>
	}

	struct Listing<phantom T: key + store> has key, store {
		id: UID,
		asset_id: ID,
		owner: address
	}

	fun init(ctx: &mut TxContext) {
		transfer::share_object(ClaimingPlatform {
			id: object::new(ctx),
			admin: tx_context::sender(ctx),
			operators: vec_set::empty()
		});
	}

	public entry fun set_operator(
		platform: &mut ClaimingPlatform,
		operator: address,
		is_operator: bool,
		ctx: &mut TxContext
	) {
		assert!(tx_context::sender(ctx) == platform.admin, ENotAdmin);
		if (is_operator) {
			if (!vec_set::contains(&platform.operators, &operator)) {
				vec_set::insert(&mut platform.operators, operator);
			}
		} else {
			if (vec_set::contains(&platform.operators, &operator)) {
				vec_set::remove(&mut platform.operators, &operator);
			}
		}
	}

	public entry fun list_assets<T: key + store>(
		platform: &mut ClaimingPlatform,
		assets: vector<T>,
		ctx: &mut TxContext
	): vector<ID> {
		let listing_ids = vector::empty<ID>();
		while (vector::length(&assets) > 0) {
			let asset = vector::pop_back(&mut assets);
			let asset_id = object::id<T>(&asset);
			let listing = Listing<T> {
				id: object::new(ctx),
				asset_id,
				owner: tx_context::sender(ctx),
			};
			let listing_id = object::id(&listing);
			dof::add(&mut platform.id, asset_id, asset);
			dof::add(&mut platform.id, listing_id, listing);
			vector::push_back(&mut listing_ids, listing_id);
		};
		vector::destroy_empty(assets);
		listing_ids
	}

	public entry fun delist_assets<T: key + store>(
		platform: &mut ClaimingPlatform,
		listing_ids: vector<ID>,
		ctx: &mut TxContext
	): vector<ID> {
		let asset_ids = vector::empty<ID>();
		while (vector::length(&listing_ids) > 0) {
			let Listing { id, asset_id, owner } = dof::remove<ID, Listing<T>>(
				&mut platform.id,
				vector::pop_back(&mut listing_ids)
			);
			assert!(tx_context::sender(ctx) == owner, ENotAssetOwner);
			let asset = dof::remove<ID, T>(&mut platform.id, asset_id);
			let asset_id = object::id(&asset);
			object::delete(id);
			transfer::public_transfer(asset, tx_context::sender(ctx));
			vector::push_back(&mut asset_ids, asset_id);
		};
		vector::destroy_empty(listing_ids);
		asset_ids
	}

	public entry fun claim_assets<T: key + store>(
		platform: &mut ClaimingPlatform,
		campaign_id: vector<u8>,
		campaign_creator: address,
		listing_ids: vector<ID>,
		operator_pubkey: vector<u8>,
		signature: vector<u8>,
		ctx: &TxContext
	) {
		// Verify the operator public key
		let operator = utils::pubkey_to_address(operator_pubkey);
		assert!(vec_set::contains(&platform.operators, &operator), ENotOperator);

		// Verify the signature
		let message = campaign_id;
		vector::append(&mut message, bcs::to_bytes(&campaign_creator));
		vector::append(&mut message, bcs::to_bytes(&tx_context::sender(ctx)));
		let i = 0;
		while (i < vector::length(&listing_ids)) {
			vector::append(&mut message, object::id_to_bytes(vector::borrow(&listing_ids, i)));
			i = i + 1;
		};
		vector::append(&mut message, operator_pubkey);
		let validity = ed25519::ed25519_verify(
			&signature,
			&operator_pubkey,
			&hash::blake2b256(&message)
		);
		assert!(validity, EInvalidSignature);

		// Return the assets to the winner
		while (vector::length(&listing_ids) > 0) {
			let Listing { id, asset_id, owner } = dof::remove<ID, Listing<T>>(
				&mut platform.id,
				vector::pop_back(&mut listing_ids)
			);
			assert!(campaign_creator == owner, ENotCampaignCreator);
			let asset = dof::remove<ID, T>(&mut platform.id, asset_id);
			object::delete(id);
			transfer::public_transfer(asset, tx_context::sender(ctx));
		};
		vector::destroy_empty(listing_ids);
	}

	#[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx)
    }
}