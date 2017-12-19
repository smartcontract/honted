import json
import sys

from ethereum import tester, utils
from ethereum.tester import TransactionFailed
import pytest
from populus.wait import Wait

LARGE_AMOUNT = utils.denoms.ether
MEDIUM_AMOUNT = 10000
SMALL_AMOUNT = 10
ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

from omg_contract_codes import OMGTOKEN_CONTRACT_ABI, OMGTOKEN_CONTRACT_BYTECODE

def deploy(web3, ContractClass):
    deploy_tx = ContractClass.deploy()
    Wait(web3).for_receipt(deploy_tx)
    deploy_receipt = web3.eth.getTransactionReceipt(deploy_tx)
    return ContractClass(address=deploy_receipt['contractAddress'])

@pytest.fixture()
def token(chain, accounts):
    owner = accounts[0]
    contract_class = chain.web3.eth.contract(abi=json.loads(OMGTOKEN_CONTRACT_ABI),
                                             bytecode=OMGTOKEN_CONTRACT_BYTECODE)
    token = deploy(chain.web3, contract_class)
    for validator in accounts:
        chain.wait.for_receipt(
            token.transact({'from': owner}).mint(validator, LARGE_AMOUNT))
    chain.wait.for_receipt(
        token.transact({'from': owner}).finishMinting())
    return token

@pytest.fixture()
def staking(token, chain, accounts):
    owner = accounts[0]
    epoch_length = 40
    maturity_margin = 5
    max_validators = 4
    staking, _ = chain.provider.get_or_deploy_contract('HonteStaking',
                                                       deploy_transaction={'from': owner},
                                                       deploy_args=[epoch_length,
                                                                    maturity_margin,
                                                                    token.address,
                                                                    max_validators])
    return staking

def jump_to_block(chain, to_block_no):
    current_block = chain.web3.eth.blockNumber
    assert current_block < to_block_no
    # the "-1" is here, because it will mine until `to_block_no - 1` which will make `to_block_no` the current block
    # that the next transaction will be "in"
    chain.web3.testing.mine(to_block_no - current_block - 1)
    assert chain.web3.eth.blockNumber == to_block_no - 1

def get_validators(staking, epoch):
    result = []
    for i in range(0, sys.maxsize**10):
        validator = staking.call().validatorSets(epoch, i)
        owner = validator[2]
        if owner == ZERO_ADDRESS:
            break
        result.append(tuple(validator))
    return result

@pytest.fixture()
def do(chain, token, staking):
    # special class that operates on the deployed contracts from the fixtures
    class Doer:
        # successful deposit (two steps!)
        def deposit(self, address, amount):
            initial = staking.call().deposits(address, 0)
            chain.wait.for_receipt(
                token.transact({'from': address}).approve(staking.address, amount))
            chain.wait.for_receipt(
                staking.transact({'from': address}).deposit(amount))
            assert initial + amount == staking.call().deposits(address, 0)
        # successful withdrawal
        def withdraw(self, address, epoch = 0):
            free_tokens = token.call().balanceOf(address)
            amount = staking.call().deposits(address, epoch)
            staking.transact({'from': address}).withdraw(epoch)
            assert 0 == staking.call().deposits(address, epoch)
            assert amount + free_tokens == token.call().balanceOf(address)
    return Doer()

def test_empty_validators(chain, staking):
    assert [] == get_validators(staking, 0)

def test_deposit_and_immediate_withdraw(do, accounts):
    do.deposit(accounts[1], LARGE_AMOUNT)
    do.withdraw(accounts[1])

def test_cant_withdraw_zero(staking, do, accounts):
    do.deposit(accounts[1], LARGE_AMOUNT)

    # someone else can't withdraw
    with pytest.raises(TransactionFailed):
        staking.transact({'from': accounts[2]}).withdraw(0)

    # if I withdrew, I can't withdraw more
    do.withdraw(accounts[1])
    with pytest.raises(TransactionFailed):
        staking.transact({'from': accounts[1]}).withdraw(0)

def test_deposit_join_withdraw_single_validator(do, chain, staking, token, accounts):
    validator = accounts[1]
    do.deposit(validator, LARGE_AMOUNT)
    staking.transact({'from': validator}).join(validator)
    # not a validator yet
    # can't withdraw after joining
    for epoch in range(0, staking.call().getCurrentEpoch() + 1 + staking.call().unbondingPeriod()):
        with pytest.raises(TransactionFailed):
            staking.transact({'from': validator}).withdraw(epoch)

    # can't withdraw while validating
    # become a validator (time passes)
    validating_epoch_start = staking.call().startBlock() + staking.call().epochLength()
    jump_to_block(chain, validating_epoch_start)
    for epoch in range(0, staking.call().getCurrentEpoch() + 1 + staking.call().unbondingPeriod()):
        with pytest.raises(TransactionFailed):
            staking.transact({'from': validator}).withdraw(epoch)

    # can't withdraw after validating, but before unbonding
    # wait until the end of the epoch
    validating_epoch_end = staking.call().startBlock() + 2 * staking.call().epochLength()
    jump_to_block(chain, validating_epoch_end)
    # fail while attempting to withdraw token which is still bonded
    for epoch in range(0, staking.call().getCurrentEpoch() + 1 + staking.call().unbondingPeriod()):
        with pytest.raises(TransactionFailed):
            staking.transact({'from': validator}).withdraw(epoch)

    # withdraw after unbonding
    # wait until the unbonding period
    unbonding_period_end = staking.call().startBlock() + 3 * staking.call().epochLength()
    jump_to_block(chain, unbonding_period_end)
    # now withdraw should work
    do.withdraw(validator, staking.call().getCurrentEpoch())

def test_cant_join_outside_join_window(do, chain, staking, accounts):
    address = accounts[1]
    do.deposit(address, LARGE_AMOUNT)
    start_block = staking.call().startBlock()
    epoch_length = staking.call().epochLength()
    maturity_margin = staking.call().maturityMargin()

    for margin_block in range(maturity_margin):
        jump_to_block(chain, start_block + epoch_length - maturity_margin + margin_block)
        with pytest.raises(TransactionFailed):
            staking.transact({'from': address}).join(address)
    # can join right after
    jump_to_block(chain, start_block + epoch_length + 1)
    staking.transact({'from': address}).join(address)

def test_deposit_join_many_validators(do, chain, staking, token, accounts):
    max = staking.call().maxNumberOfValidators()
    for validator in accounts[:max]:
        do.deposit(validator, LARGE_AMOUNT)
        chain.wait.for_receipt(
            staking.transact({'from': validator}).join(validator))

def test_ejects_smallest_validators(do, chain, staking, token, accounts):
    max_validators = staking.call().maxNumberOfValidators()
    prior_validators = accounts[0:max_validators]
    smallest_validator = accounts[2]
    for idx, validator in enumerate(prior_validators):
        if validator != smallest_validator:
            do.deposit(validator, (idx + 1) * MEDIUM_AMOUNT)
        else:
            do.deposit(validator, SMALL_AMOUNT)

        chain.wait.for_receipt(
            staking.transact({'from': validator}).join(validator))

    # ejecting
    new_validator = accounts[max_validators]
    new_amount = (max_validators + 1) * MEDIUM_AMOUNT
    do.deposit(new_validator, new_amount)

    chain.wait.for_receipt(
        staking.transact({'from': new_validator}).join(new_validator))

    validators = get_validators(staking, 1)
    validators_addresses = [validator[1] for validator in validators]  # just the addresses
    assert len(validators) == max_validators
    assert smallest_validator not in validators_addresses
    assert (new_amount, new_validator, new_validator) in validators

def test_cant_enter_if_too_small_to_eject(do, staking, token, accounts):
    max_validators = staking.call().maxNumberOfValidators()

    # larger players
    for idx_validator in range(max_validators):
        validator = accounts[idx_validator]
        do.deposit(validator, LARGE_AMOUNT)
        staking.transact({'from': validator}).join(validator)

    small_validator = accounts[max_validators]
    small_amount = utils.denoms.wei
    do.deposit(small_validator, small_amount)
    with pytest.raises(TransactionFailed):
        staking.transact({'from': small_validator}).join(small_validator)

def test_deposits_accumulate_for_join(chain, do, staking, token, accounts):
    validator = accounts[1]
    do.deposit(validator, utils.denoms.finney)
    do.deposit(validator, utils.denoms.finney)
    chain.wait.for_receipt(
       staking.transact({'from': validator}).join(validator))
    validators = get_validators(staking, 1)
    assert len(validators) == 1
    stake, _, owner = validators[0]
    assert stake == 2 * utils.denoms.finney
    assert owner == validator

def test_deposits_accumulate_for_withdraw(do, token, accounts):
    validator = accounts[1]
    do.deposit(validator, utils.denoms.finney)
    do.deposit(validator, utils.denoms.finney)
    current = token.call().balanceOf(validator)
    do.withdraw(validator)
    assert current + 2*utils.denoms.finney == token.call().balanceOf(validator)

@pytest.fixture
def lots_of_staking_past(do, chain, staking, accounts):
    max_validators = staking.call().maxNumberOfValidators()
    validators = accounts[0:max_validators]

    # several epochs with stakers one after another
    for _ in range(5):
        for validator in validators:
            do.deposit(validator, MEDIUM_AMOUNT)
            chain.wait.for_receipt(staking.transact({'from': validator}).join(validator))
        jump_to_block(chain, staking.call().getNextEpochBlockNumber())

def test_can_withdraw_from_old_epoch(do, lots_of_staking_past, chain, staking, token, accounts):
    validator = accounts[1]
    do.deposit(validator, MEDIUM_AMOUNT)
    staking.transact({'from': validator}).join(validator)
    withdraw_epoch = staking.call().getCurrentEpoch() + 1 + staking.call().unbondingPeriod() + 1
    much_later = staking.call().startBlock() + 30 * staking.call().epochLength()
    jump_to_block(chain, much_later)
    # now withdraw should still work
    do.withdraw(validator, withdraw_epoch)

def test_can_lookup_validators_from_the_past(do, lots_of_staking_past, chain, staking, token,
                                             accounts):
    much_later = staking.call().startBlock() + 30 * staking.call().epochLength()
    jump_to_block(chain, much_later)
    # now old stakes should still be reachable
    for epoch in range(5):
        validators = get_validators(staking, epoch + 1)  # +1 because we were _joining_ in epochs 0 through 4
        assert len(validators) == staking.call().maxNumberOfValidators()
        for idx, validator in enumerate(validators):
            assert validator[0] == MEDIUM_AMOUNT
            assert validator[1] == accounts[idx]
            assert validator[2] == accounts[idx]

def test_can_withdraw_accumulated_old_deposits():
    pass

def test_join_does_continue_in_validating_epoch():
    pass

def test_cant_continue_in_unbonding_epoch():
    pass

def test_eject_continueing_withdraws_work():
    pass

def test_correct_duplicate_join_of_a_single_validator():
    pass

def test_validator_can_continue_with_a_small_addition_to_stake():
    pass
