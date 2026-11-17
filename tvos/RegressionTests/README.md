# Apple TV regression checks

This separate simulator app keeps Keychain save/restore tests isolated from the real Ant Streams app and its saved providers. Its ad-hoc signing identity is simulator-only and requires no Apple developer account. Tests use mock provider/account credentials; they never change a real Supabase account. Network preloads may fail harmlessly when no local fixture server is running.

After installing the main tvOS Pods, run:

```sh
cd tvos/RegressionTests
xcodegen generate --spec project.json
xcodebuild test -project AntStreamsRegression.xcodeproj -scheme AntStreamsRegression -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -derivedDataPath /tmp/AntStreamsRegression
```

Coverage includes provider saves and source selection across a new app model, account/device precedence, failed saves, deletion, grouped TV-show versions, known release-year distinctions, and category/language preference migration. The production app and test host have different bundle IDs and Keychain access groups.
