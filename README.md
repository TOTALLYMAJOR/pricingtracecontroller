# Pricing Trace Explorer

An interview-grade Salesforce Revenue Cloud starter that turns opaque pricing behavior into a visible execution narrative.

This repo implements a portfolio-ready **Lightning Web Component + Apex service layer** for one of the most common Revenue Cloud pain points:

> sellers, deal desk, and support teams cannot easily explain why a price changed.

The component consolidates pricing execution, adjustments, tier logic, procedure decisions, and amendment-style deltas into one record-page experience. It is designed to be **safe to deploy in a generic org** while still becoming useful in a Revenue Cloud org through runtime object discovery.

## Why this stands out

Most sample Salesforce repos stop at CRUD screens. This one is intentionally closer to real architecture work:

- Solves a legitimate Revenue Cloud observability problem instead of another generic quote calculator.
- Uses a service contract and dynamic schema inspection so the package can compile without hard managed-package dependencies.
- Includes a recruiter-friendly demo mode for screenshots, demos, and portfolio walkthroughs.
- Preserves a path to real org integration with live trace objects and headless pricing replay.

## What it does

`Pricing Trace Explorer` can be dropped onto a record page or opened on an app/home page in demo mode.

It provides:

- A pricing timeline from baseline price to final net result.
- Adjustment cards that show source, impact direction, and override state.
- A tier visualizer for quantity/rate/value transparency.
- A procedure tree that makes pricing logic human-readable.
- A delta panel that frames the business impact like an amendment analysis.
- A replay console that simulates a headless repricing scenario without saving data.
- A source-health panel that explains which trace objects were actually reachable in the org.
- A risk radar for slow pricing paths, overlapping tiers, and ambiguous multi-execution traces.

## Architecture

```mermaid
flowchart TD
    A[LWC: pricingTraceExplorer] --> B[Apex: PricingTraceController]
    B --> C[Apex: PricingTraceService]
    C --> D[Dynamic schema discovery]
    C --> E[Dynamic SOQL over Revenue Cloud trace objects]
    C --> F[Demo dataset and heuristic replay engine]
    E --> G[PricingAPIExecution]
    E --> H[PricingProcessExecution]
    E --> I[PricingProcedureResolution]
    E --> J[QuoteLineRateAdjustment]
    E --> K[QuoteLineRateCardEntry]
    E --> L[PriceAdjustmentTier]
    E --> M[ContractItemPrice]
    E --> N[OrderItemRateAdjustment]
```

### Design choices

- **No hard package dependency**: object and field access is resolved with `Schema.getGlobalDescribe()` and semantic field candidate lists.
- **Security-first**: `with sharing`, access checks on describes, and `Security.stripInaccessible(...)` on queried records.
- **Live + demo modes**: live mode uses discovered objects; demo mode guarantees a clean narrative for recruiter walkthroughs.
- **Heuristic replay**: the shipped replay is package-agnostic on purpose, but the service contract is already aligned to swap in a real headless pricing call later.

## Repo layout

```text
force-app/main/default/
  classes/
    PricingTraceController.cls
    PricingTraceService.cls
    PricingTraceServiceTest.cls
  lwc/
    pricingTraceExplorer/
      pricingTraceExplorer.html
      pricingTraceExplorer.js
      pricingTraceExplorer.css
      pricingTraceExplorer.js-meta.xml
  permissionsets/
    Pricing_Trace_Explorer.permissionset-meta.xml
manifest/
  package.xml
```

## Deploy

### Salesforce CLI deploy

```bash
sf project deploy start --manifest manifest/package.xml --target-org <your-org-alias>
```

### Assign access

```bash
sf org assign permset --name Pricing_Trace_Explorer --target-org <your-org-alias>
```

## Add to a page

1. Open Lightning App Builder.
2. Add **Pricing Trace Explorer** to a Record, App, or Home page.
3. Turn on `Start In Demo Mode` if you want a clean portfolio walkthrough immediately.
4. On a Revenue Cloud org, leave demo mode off to let the component discover live trace records.

## Live-org behavior

In a Revenue Cloud org, the service attempts to discover and query these sources when available:

- `PricingAPIExecution`
- `PricingProcessExecution`
- `PricingProcedureResolution`
- `QuoteLineRateCardEntry`
- `QuoteLineRateAdjustment`
- `OrderItemRateAdjustment`
- `PriceAdjustmentTier`
- `ContractItemPrice`

If those objects or fields are not present, inaccessible, or not linked to the current record, the UI explains that instead of failing silently.

## Security notes

- The Apex classes run `with sharing`.
- Source objects are only queried when the current user can access them.
- Retrieved records are passed through `Security.stripInaccessible(...)`.
- The included permission set only grants Apex class access.
- Revenue Cloud object CRUD/FLS must still be granted according to your org security model.

## Headless pricing replay path

The shipped replay console uses a heuristic pricing model so the repo remains deployable anywhere.

To upgrade it in a real implementation:

1. Replace the replay calculation in `PricingTraceService.simulateReplay(...)`.
2. Call the org’s preferred headless pricing endpoint or invocable action.
3. Return the same `ReplayResponse` contract so the LWC remains unchanged.

## Portfolio framing

If a recruiter or hiring manager asks why this repo matters:

> Revenue Cloud pricing engines are powerful but opaque. This project adds observability, analyst trust, and faster issue resolution by surfacing pricing execution, adjustments, tiering, and procedure logic in one place.

That positions the repo as **architectural product thinking**, not just UI customization.

## Known limitations

- No live org is connected in this repo, so deployment and Apex compilation were not validated against a target org here.
- Managed-package object and field names vary by implementation; this starter uses semantic candidate lists and safe fallback behavior.
- The replay flow is intentionally heuristic until wired to a real pricing endpoint.

## Next extensions

- Replace heuristic replay with a real Revenue Cloud headless pricing action.
- Add conflict detection for overlapping procedures and overridden adjustments.
- Add a persistence layer for historical trace comparisons across quote, order, and amendment events.
- Add screenshots or a short demo recording once deployed to a sample org.
