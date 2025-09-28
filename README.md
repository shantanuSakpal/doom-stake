# Doom Stake 🌿

## Problem

We waste countless hours on distracting apps — even when we set screen-time limits, it’s too easy to bypass them. Traditional blockers don’t give us real commitment or accountability.

## Solution

**Doom Stake** lets you put skin in the game. You stake FLOW tokens to block apps for a set duration. If you break your promise and open a blocked app, your stake can be slashed. If you stay disciplined, you earn rewards.

## What We Provide

- 📱 **Smart App Blocking**: Choose apps and set custom time limits.
- ⛓️ **Onchain Staking**: Stake FLOW with real value at risk.
- ⚖️ **Fair Rewards & Slashing**: Earn if you stick to your limits, lose if you don’t.
- 🌿 **Touch Grass Unlocks**: Extend limits by verifying you actually go outside.
- 📊 **Usage Stats**: Track your daily screen time and active blocks.

Stay productive, stay healthy — and make your discipline **unstoppable**.

---

## Technical Details

### Stack

- **Frontend/App**: Flutter (Android focused, Material 3 design)
- **Blockchain**: Flow EVM Testnet (EVM-compatible)
- **Wallet/Auth**: Web3Auth (passwordless email login → EVM private key)
- **Smart Contracts**: Solidity
  - Stake FLOW (`stake(uint256 _stakeTime)`)
  - Withdraw (`withdraw()`)
  - Slash misbehaving users (`slash(address user)`)
  - Track stakes with mapping `stakes(address)` → `(amount, timestamp, active)`
- **Backend**: Node.js/Express + Ngrok (for slash API & image verification)

### Features Implemented

- App usage monitoring using `usage_stats` and `installed_apps` Flutter plugins
- Overlay blocker via `system_alert_window`
- Onchain staking via `web3dart`
- Reward pool + TVL tracking (`totalStaked()`, `currentReward()`)
- User stake info query (`stakes(address)`)
- Camera unlock → upload to backend → AI verification → extend time by 1 min
- Slash API endpoint that slashes a user’s stake if they open blocked apps

### Environment Variables (`.env`)

```env
WEB3AUTH_CLIENT_ID=your_web3auth_client_id
NGROK_BASE_URL=https://xxxxxx.ngrok-free.app

Setup

Clone the repo

Install Flutter dependencies

flutter pub get


Configure .env file with Web3Auth client ID and ngrok backend URL

Run the app

flutter run
```
