import pytest
from brownie import config, Wei, Contract


@pytest.fixture
def gov(accounts):
    # ychad.eth
    yield accounts.at('0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52', force=True)


@pytest.fixture
def rewards(gov):
    yield gov  # TODO: Add rewards contract


@pytest.fixture
def guardian(accounts):
    # dev.ychad.eth
    yield accounts.at('0x846e211e8ba920B353FB717631C015cf04061Cc9', force=True)


@pytest.fixture
def management(accounts):
    # dev.ychad.eth
    yield accounts.at('0x846e211e8ba920B353FB717631C015cf04061Cc9', force=True)


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490"  # this should be the address of the ERC-20 used by the strategy/vault
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, whale):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = whale
    yield amount


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(accounts, strategist, keeper, vault, Strategy, gov, token):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})

    proxy = Contract("0x9a165622a744C20E3B2CB443AeD98110a33a231b", owner=gov)
    voter = Contract(proxy.proxy(), owner=gov)
    gauge = Contract(strategy.gauge())

    # harvest the old strategy
    ctrl = Contract('0x9E65Ad11b299CA0Abefc2799dDB6314Ef2d91080', owner=gov)
    old_strategy = Contract(ctrl.strategies(token), owner=gov)
    old_vault = Contract(ctrl.vaults(token), owner=gov)
    # old_strategy.harvest()

    # remove the old strategy from gauge
    data = vault.withdraw.encode_input(gauge.balanceOf(voter)) # just use the vault interface
    voter.execute(gauge, 0, data)

    # transfer token from voter to old vault
    data = token.transfer.encode_input(old_vault, token.balanceOf(voter))
    voter.execute(token, 0, data)
    assert token.balanceOf(voter) == 0
    assert gauge.balanceOf(voter) == 0

    # clear mintr
    mintr = Contract(proxy.mintr())
    data = mintr.mint.encode_input(gauge)
    voter.execute(mintr, 0, data)

    # sent to strategy
    crv = Contract('0xD533a949740bb3306d119CC777fa900bA034cd52')
    data = token.transfer.encode_input(strategy, token.balanceOf(voter))
    voter.execute(crv, 0, data)

    # change current strategy proxy
    mock_proxy = '0x96Dd07B6c99b22F3f0cB1836aFF8530a98BDe9E3'
    old_strategy.setProxy(mock_proxy) # arbitrary proxy address

    # proxy add
    # proxy = Contract("0x96Dd07B6c99b22F3f0cB1836aFF8530a98BDe9E3")
    # governance = proxy.governance()
    # proxy.approveStrategy(gauge, strategy, {'from': governance})
    proxy.approveStrategy(gauge, strategy)

    yield strategy


@pytest.fixture
def whale(accounts):
    # binance7 wallet
    # acc = accounts.at('0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8', force=True)

    # binance8 wallet
    #acc = accounts.at('0xf977814e90da44bfa03b6295a0616a897441acec', force=True)

    # veCRV DAO yVault
    acc = accounts.at('0xc5bDdf9843308380375a611c18B50Fb9341f502A', force=True)
    yield acc
