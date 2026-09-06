# Reward Shop

`ShopScreen` supplies page content to the existing Home navigation shell. Inject
the same committed read stream, economy repository and item editor as the rest
of the app:

```dart
HomeRoutes(
  shop: (_) => ShopScreen(
    watchShop: () => watchSqliteHome(store),
    economy: economy,
    editing: editing,
  ),
  // Supply the other feature routes from the native composition root.
)
```

Import `features/shop/shop.dart` and `features/home/home.dart`. The shell retains
its one wallet header, navigation and compact active timer. Shop has no separate
store, clock, default currency metadata, or sample prices. Native composition
chooses the live repositories; the parameterless app remains the foundation
preview until that composition is supplied.

The catalog shows every unarchived Award definition, including offers without an
owned balance. Redeem opens a centered, scrollable dialog; Configure opens the
existing editor. A purchase adds both allowance dimensions to the existing Award
row, and the shared store stream immediately refreshes Home and the wallet.
Purchases are allowed during running or paused sessions without changing them.

Quantity input, plus/minus and the slider share a single whole-pack draft. Direct
input may exceed affordability so the dialog can show the exact Coins/Gems
shortage and an action to use the affordable quantity. Both currencies remain
visible, including zero-price dimensions. All monetary and allowance calculations
use checked integers. The slider uses normalized geometry, with exact integer
endpoints; direct entry remains exact throughout the signed 64-bit range.
Pooled allowance capacity may further restrict the purchasable maximum.

The preview comes from one committed item/wallet/allowance snapshot. Redemption
revalidates the item revision and balances transactionally. A changed offer is
displayed with a distinct confirmation action; a rejected stale purchase never
submits itself again. The dialog retains quantity during insufficient-funds,
revision and storage recovery. Read errors disable purchase using stale data.

Submission disables dismissal and quantity editing. Each new purchase gets one
operation ID. A storage failure or lost response keeps the same immutable request
and its original preview for retry, including when the original already committed.
The retry cannot become a second purchase. Successful completion closes the
dialog and confirms the addition to My Trove. Cancelling before submission has
no economic effect; cancellation after an uncertain response cannot undo a
purchase that already committed.

Run the SQLite-backed widget and controller checks with:

```sh
flutter test test/features/shop_test.dart --reporter expanded
flutter test test/features/shop_test.dart --dart-define=UI_EVIDENCE=true
```

[Synthetic UI evidence](../../../docs/ui-evidence/shop/README.md) covers normal
and large-text layouts. Native VoiceOver/TalkBack and physical-device validation
belong to the native acceptance suite; widget tests do not establish those results.
