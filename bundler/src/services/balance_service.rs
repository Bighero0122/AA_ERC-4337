use ethers::abi::Address;
use ethers::providers::{Http, Middleware, Provider};
use log::info;

use crate::contracts::usdc_provider::ERC20;
use crate::db::dao::metadata_dao::MetadataDao;
use crate::db::dao::wallet_dao::WalletDao;
use crate::errors::ApiError;
use crate::models::currency::Currency;
use crate::models::wallet::balance_response::BalanceResponse;
use crate::PROVIDER;

#[derive(Clone)]
pub struct BalanceService {
    pub wallet_dao: WalletDao,
    pub metadata_dao: MetadataDao,
    pub erc20_provider: ERC20<Provider<Http>>,
}

impl BalanceService {
    pub async fn get_wallet_balance(
        &self,
        chain: &String,
        currency: &String,
        user: &str,
    ) -> Result<BalanceResponse, ApiError> {
        info!("Chain: {:?}", chain); // will be relevant when we add support for multiple chains
        let mut balance: String = "0".to_string();
        let address = self.wallet_dao.get_wallet_address(user.to_string()).await;
        if address.is_empty() {
            return Err(ApiError::NotFound("Wallet not found".to_string()));
        }
        let user: Address = address.parse().unwrap();

        match Currency::from_str(currency.clone()) {
            None => {}
            Some(Currency::Usdc) => {
                balance = self
                    .erc20_provider
                    .balance_of(user.clone())
                    .await
                    .unwrap()
                    .to_string();
            }
            Some(Currency::SepoliaEth) | Some(Currency::GoerliEth) | Some(Currency::LocalEth) => {
                balance = PROVIDER
                    .get_balance(user.clone(), None)
                    .await
                    .unwrap()
                    .to_string();
            }
        }

        Ok(BalanceResponse {
            balance: balance.clone(),
            address: address.clone(),
            currency: currency.to_string(),
            exponent: self
                .metadata_dao
                .get_metadata_for_chain_and_currency(chain.clone(), currency.to_string())
                .await[0]
                .exponent,
        })
    }
}
