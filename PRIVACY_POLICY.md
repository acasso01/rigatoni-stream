# Ant Streams Privacy Policy

**Last updated: November 14, 2026**

Ant Streams is a media player for iPhone, iPad, and Apple TV. It does not provide, host, or include TV channels, movies, or other streaming content. You add your own provider details and are responsible for having the right to access the content you play.

## Use without an account

The iPhone, iPad, and Apple TV apps can be used without an Ant Streams account. Enter the IPTV provider server URL, username, password, and an optional name. Those provider credentials are stored in the device Keychain for that device only. They are not written to preferences, logs, or disk caches, and they are not sent to the account service unless you choose Sign in to sync. They are sent to the provider you choose when the app requests a catalog or plays media. Favorites, viewing progress, and history stay on the device under a hashed namespace. Optional account sign-in syncs provider settings with the encrypted account vault and is required for the HTTPS gateway. Direct providers play without an account. The website still uses the account vault.

## Information the app handles

Ant Streams handles the information needed to provide its features:

- **Account information:** If you create or use an Ant Streams account, your email address and account credentials are sent to the app's account service, powered by Supabase. The service issues sign-in tokens that the app stores in the device Keychain.
- **Provider information:** The server address, username, password, optional name, and optional gateway details you enter are used to connect to the provider you choose. Provider credentials are sent to that provider when the app requests its catalog or plays media. On iPhone, iPad, and Apple TV they are saved in the device Keychain. If you sign in, the app also saves them in the account vault so they can be restored on another sign-in.
- **Playback and personalization information:** The app may save preferences, hidden categories, favorites, and playback progress on your device. Those lists are scoped to the signed-in account or to the provider saved on that device. They do not include provider passwords or stream URLs.
- **Network information:** When connecting to the account service, your provider, or media servers, those services may receive technical information such as your IP address and standard connection data. Their handling of that information is governed by their own privacy policies.

Ant Streams does not include advertising or analytics in the reviewed app source. This policy does not cover information handled by Apple, your streaming provider, or other services you choose to use.

## How information is used

Information is used to authenticate your account, save and restore your settings, load catalogs and guides, and play media from the provider you configure. Ant Streams does not sell your personal information.

## Storage and security

Account sign-in tokens, when you sign in, are stored in the device Keychain. Provider logins entered without an account are stored in a separate Keychain item that stays on that device. The account service stores a provider only after you sign in and save. Other preferences, favorites, and history are stored locally on your device. No internet transmission can be guaranteed completely secure; use providers and networks you trust.

## Your choices and deletion

You can stop using a provider by removing its details in the app. You can sign out to remove the saved sign-in token from that device. For deletion of an Ant Streams account and associated information held by the account service, contact the developer at **anthonyaldom1@gmail.com**. The app's settings also include an account-vault deletion action; confirm the intended behavior in the submitted release before relying on this option.

## Children's privacy

Ant Streams is not directed to children and does not knowingly collect personal information from children.

## Changes and contact

This policy may be updated when the app's behavior changes. Questions or privacy requests can be sent to **anthonyaldom1@gmail.com**.
