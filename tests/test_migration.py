# TODO: Add tests that show proper migration of the strategy to a newer one
#       Use another copy of the strategy to simulate the migration
#       Show that nothing is lost!
import pytest
from brownie import config
from brownie import Contract

@pytest.fixture
def new_strategy(accounts, strategist, keeper, vault, Strategy, gov):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper)

    yield strategy


def test_migration_via_vault(gov, vault, strategy, new_strategy):
    oldStrategyAssets = strategy.estimatedTotalAssets()
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert oldStrategyAssets == new_strategy.estimatedTotalAssets()


def test_migration_via_strategy(gov, vault, strategy, new_strategy):
    oldStrategyAssets = strategy.estimatedTotalAssets()
    strategy.migrate(new_strategy, {"from": gov})
    assert oldStrategyAssets == new_strategy.estimatedTotalAssets()


def test_migration():
    pass
