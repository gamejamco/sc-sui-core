module superfine::superfine_airdrop {
	use std::vector;
	use std::bcs;
	use sui::object::{Self, ID, UID};
	use sui::transfer;
	use sui::tx_context::{Self, TxContext};
	use sui::dynamic_object_field as dof;
	use sui::ed25519;
	use sui::hash;
	use sui::vec_set::{Self, VecSet};
	use sui::coin::{Self, Coin};
    use sui::sui::SUI;
	use sui::address;
	use sui::balance::{Self, Balance};
	use sui::event;

	const ECampaignAirdropStarted: u64 = 135289670000;
	const ENotCampaignCreator: u64 = 135289670000 + 1;
	const EInvalidSignature: u64 =  135289670000 + 2;
	const ENotAdmin: u64 = 135289670000 + 3;
	const ENotOperator: u64 = 135289670000 + 4;
	const ECampaignAlreadyCreated: u64 = 135289670000 + 5;
	const ETooManyAssets: u64 = 135289670000 + 6;
	const ENumAssetsTooLow: u64 = 135289670000 + 7;

	struct AirdropPlatform has key {
		id: UID,
		admin: address,
		operators: VecSet<address>,
		airdrop_fee: Balance<SUI>,
		campaign_ids: VecSet<vector<u8>>
	}

	struct AirdropCampaign has key, store {
		id: UID,
		campaign_id: vector<u8>,
		creator: address,
		num_assets: u64,
		charged_fee: u64,
		airdrop_started: bool,
		asset_count: u64
	}

	struct EventCampaignCreated has copy, drop {
		id: ID,
		campaign_id: vector<u8>,
		asset_ids: vector<ID>
	}

	struct EventCampaignUpdated has copy, drop {
		campaign_id: ID
	}

	fun init(ctx: &mut TxContext) {
		transfer::share_object(AirdropPlatform {
			id: object::new(ctx),
			admin: tx_context::sender(ctx),
			operators: vec_set::empty(),
			airdrop_fee: balance::zero<SUI>(),
			campaign_ids: vec_set::empty()
		});
	}

	public entry fun set_operator(
		platform: &mut AirdropPlatform,
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

	public entry fun create_airdrop_campaign<T: key + store>(
		platform: &mut AirdropPlatform,
		campaign_id: vector<u8>,
		num_assets: u64,
		airdrop_fee: u64,
		assets: vector<T>,
		operator_pubkey: vector<u8>,
		signature: vector<u8>,
		payment: &mut Coin<SUI>,
		ctx: &mut TxContext
	): ID {
		// Verify the operator public key
		let operator = pubkey_to_address(operator_pubkey);
		assert!(vec_set::contains(&platform.operators, &operator), ENotOperator);

		// Verify the signature
		let message = campaign_id;
		vector::append(&mut message, bcs::to_bytes(&tx_context::sender(ctx)));
		vector::append(&mut message, u64_to_bytes(num_assets));
		vector::append(&mut message, u64_to_bytes(airdrop_fee));
		vector::append(&mut message, operator_pubkey);
		let validity = ed25519::ed25519_verify(
			&signature,
			&operator_pubkey,
			&hash::blake2b256(&message)
		);
		assert!(validity, EInvalidSignature);

		// Check if campaign was created before
		assert!(!vec_set::contains(&platform.campaign_ids, &campaign_id), ECampaignAlreadyCreated);

		// Check payment
		let airdrop_coin = coin::split<SUI>(payment, airdrop_fee, ctx);
		coin::put(&mut platform.airdrop_fee, airdrop_coin);

		// Create the campaign
		let campaign = AirdropCampaign {
			id: object::new(ctx),
			campaign_id,
			creator: tx_context::sender(ctx),
			num_assets,
			charged_fee: airdrop_fee,
			airdrop_started: false,
			asset_count: 0
		};
		vec_set::insert(&mut platform.campaign_ids, campaign_id);
		let cid = object::id(&campaign);
		dof::add(&mut platform.id, cid, campaign);

		// List some initial assets
		let asset_ids = list_assets<T>(platform, cid, assets, ctx);

		event::emit(EventCampaignCreated {
			id: cid,
			campaign_id,
			asset_ids
		});
		cid
	}

	public entry fun update_campaign(
		platform: &mut AirdropPlatform,
		campaign_id: ID,
		new_num_assets: u64,
		new_airdrop_fee: u64,
		operator_pubkey: vector<u8>,
		signature: vector<u8>,
		payment: &mut Coin<SUI>,
		ctx: &mut TxContext
	): ID {
		let campaign = dof::borrow_mut<ID, AirdropCampaign>(&mut platform.id, campaign_id);

		// Verify the operator public key
		let operator = pubkey_to_address(operator_pubkey);
		assert!(vec_set::contains(&platform.operators, &operator), ENotOperator);

		// Verify the signature
		let message = campaign.campaign_id;
		vector::append(&mut message, bcs::to_bytes(&tx_context::sender(ctx)));
		vector::append(&mut message, u64_to_bytes(new_num_assets));
		vector::append(&mut message, u64_to_bytes(new_airdrop_fee));
		vector::append(&mut message, operator_pubkey);
		let validity = ed25519::ed25519_verify(
			&signature,
			&operator_pubkey,
			&hash::blake2b256(&message)
		);
		assert!(validity, EInvalidSignature);

		// Some extra checks
		assert!(!campaign.airdrop_started, ECampaignAirdropStarted);
		assert!(new_num_assets >= campaign.asset_count, ENumAssetsTooLow);
		assert!(tx_context::sender(ctx) == campaign.creator, ENotCampaignCreator);

		// Check payment
		if (new_airdrop_fee > campaign.charged_fee) {
			let airdrop_coin = coin::split<SUI>(payment, new_airdrop_fee - campaign.charged_fee, ctx);
			coin::put(&mut platform.airdrop_fee, airdrop_coin);
		};

		// Update the campaign
		campaign.num_assets = new_num_assets;
		if (new_airdrop_fee > campaign.charged_fee) {
			campaign.charged_fee = new_airdrop_fee;
		};
		let cid = object::id(campaign);
		event::emit(EventCampaignUpdated { campaign_id: cid });
		cid
	}

	public entry fun list_assets<T: key + store>(
		platform: &mut AirdropPlatform,
		campaign_id: ID,
		assets: vector<T>,
		ctx: &mut TxContext
	): vector<ID> {
		let campaign = dof::borrow_mut<ID, AirdropCampaign>(&mut platform.id, campaign_id);
		assert!(tx_context::sender(ctx) == campaign.creator, ENotCampaignCreator);
		assert!(!campaign.airdrop_started, ECampaignAirdropStarted);

		let total_assets = campaign.asset_count + vector::length(&assets);
		assert!(total_assets <= campaign.num_assets, ETooManyAssets);
		campaign.asset_count = total_assets;

		let asset_ids = vector::empty<ID>();
		while (vector::length(&assets) > 0) {
			let asset = vector::pop_back(&mut assets);
			let asset_id = object::id<T>(&asset);
			dof::add(&mut campaign.id, asset_id, asset);
			vector::push_back(&mut asset_ids, asset_id);
		};
		vector::destroy_empty(assets);
		asset_ids
	}

	public entry fun delist_asset<T: key + store>(
		platform: &mut AirdropPlatform,
		campaign_id: ID,
		asset_id: ID,
		ctx: &mut TxContext
	) {
		let campaign = dof::borrow_mut<ID, AirdropCampaign>(&mut platform.id, campaign_id);
		assert!(tx_context::sender(ctx) == campaign.creator, ENotCampaignCreator);
		assert!(!campaign.airdrop_started, ECampaignAirdropStarted);

		campaign.asset_count = campaign.asset_count - 1;
		let asset = dof::remove<ID, T>(
			&mut campaign.id,
			asset_id
		);
		transfer::public_transfer(asset, tx_context::sender(ctx));
	}

	public entry fun airdrop_asset<T: key + store>(
		platform: &mut AirdropPlatform,
		campaign_id: ID,
		asset_id: ID,
		winner: address,
		ctx: &TxContext
	) {
		let campaign = dof::borrow_mut<ID, AirdropCampaign>(&mut platform.id, campaign_id);
		assert!(vec_set::contains(&platform.operators, &tx_context::sender(ctx)), ENotOperator);
		if (!campaign.airdrop_started) {
			campaign.airdrop_started = true;
		};
		let asset = dof::remove<ID, T>(&mut campaign.id, asset_id);
		transfer::public_transfer(asset, winner);
	}

	public entry fun withdraw_airdropping_fee(
		platform: &mut AirdropPlatform,
		recipient: address,
		ctx: &mut TxContext
	) {
		assert!(tx_context::sender(ctx) == platform.admin, ENotAdmin);
		let all_fee = balance::value<SUI>(&platform.airdrop_fee);
		let coin = coin::take<SUI>(&mut platform.airdrop_fee, all_fee, ctx);
		transfer::public_transfer<Coin<SUI>>(coin, recipient);
	}

	fun u64_to_bytes(value: u64): vector<u8> {
		let result = vector::empty<u8>();
		let i = 0;
		while (i < 8) {
			vector::push_back(&mut result, ((value - ((value >> 8) << 8)) as u8));
			value = value >> 8;
			i = i + 1;
		};
		vector::reverse(&mut result);
		result
	}

	fun pubkey_to_address(pubkey: vector<u8>): address {
		let scheme: u8 = 0; // ED25519 scheme
		let data = &mut vector::empty<u8>();
		vector::push_back(data, scheme);
		vector::append(data, pubkey);
		address::from_bytes(hash::blake2b256(data))
	}

	#[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx)
    }
}