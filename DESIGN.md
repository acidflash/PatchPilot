---
name: PatchPilot
description: Self-hosted patch management and fleet control for Ubuntu server fleets.
colors:
  void-navy: "#05080f"
  surface: "#0b1120"
  surface-raised: "#0f1828"
  surface-floating: "#132035"
  border-default: "#1e2d45"
  border-subtle: "#172338"
  text-primary: "#e2eaf6"
  text-secondary: "#94a3b8"
  text-muted: "#566577"
  accent-interactive: "#4f8cff"
  accent-success: "#34d399"
  accent-warning: "#fbbf24"
  accent-danger: "#f87171"
  accent-approval: "#a78bfa"
  accent-action: "#22d3ee"
typography:
  display:
    fontFamily: "Inter, ui-sans-serif, system-ui, sans-serif"
    fontSize: "30px"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "-0.06em"
  title:
    fontFamily: "Inter, ui-sans-serif, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: "-0.02em"
  body:
    fontFamily: "Inter, ui-sans-serif, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
  label:
    fontFamily: "Inter, ui-sans-serif, system-ui, sans-serif"
    fontSize: "10.5px"
    fontWeight: 700
    lineHeight: 1.4
    letterSpacing: "0.08em"
  mono:
    fontFamily: "ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "11.5px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
rounded:
  sm: "8px"
  md: "12px"
  lg: "16px"
  pill: "999px"
spacing:
  xs: "8px"
  sm: "14px"
  md: "18px"
  lg: "24px"
  xl: "28px"
components:
  button-primary:
    backgroundColor: "#2563eb"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.sm}"
    padding: "6px 12px"
  button-primary-hover:
    backgroundColor: "#1d4ed8"
    textColor: "{colors.text-primary}"
  button-default:
    backgroundColor: "{colors.surface-floating}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.sm}"
    padding: "6px 12px"
  button-danger:
    backgroundColor: "#4a1010"
    textColor: "{colors.accent-danger}"
    rounded: "{rounded.sm}"
    padding: "6px 12px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.text-secondary}"
    rounded: "{rounded.sm}"
    padding: "6px 12px"
  badge-ok:
    backgroundColor: "#0a2e1f"
    textColor: "{colors.accent-success}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  badge-bad:
    backgroundColor: "#2e1010"
    textColor: "{colors.accent-danger}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  badge-warn:
    backgroundColor: "#2e2008"
    textColor: "{colors.accent-warning}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  badge-info:
    backgroundColor: "#0d1e3d"
    textColor: "{colors.accent-interactive}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  badge-approval:
    backgroundColor: "#1e1535"
    textColor: "{colors.accent-approval}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
---

# Design System: PatchPilot

## 1. Overview

**Creative North Star: "The Instrument Panel"**

PatchPilot's admin interface is not a dashboard. It is an instrument panel: every readout is where the operator expects it, every state is unambiguous, every action produces a predictable outcome. The visual language descends from aerospace and industrial control systems, not SaaS product design. Where a consumer product optimizes for first impressions, this interface optimizes for the 300th session. The person reading it at 2am during an incident does not want to be impressed. They want to know, immediately, which machines are affected and what to do.

The surface hierarchy is structural, not decorative. Void Navy at the base, four steps of rising brightness toward floating elements, ambient shadows for elements that genuinely float above the content plane. Nothing glows for atmosphere. Color communicates system state and nothing else: blue is interactive, green is healthy, yellow is a concern, red is urgent, purple is pending approval, cyan is an in-flight action. A color appearing where it carries none of those meanings is a design error.

This system explicitly rejects the shiny SaaS dashboard idiom: no gradient-accented metric heroes, no color deployed for energy rather than information, no glass cards used as atmosphere. Every element earns its place or does not appear.

**Key Characteristics:**
- Four-step dark surface stack from void canvas to floating elements
- Six semantic accent colors, each strictly bound to one system state
- Compressed typographic scale with extreme weight contrast (label at 10.5px/700 vs. metric at 30px/800)
- Transitions only, no choreography, no decorative motion
- High information density, near-zero decoration

## 2. Colors: The State System

The palette is a semantic state system on a dark neutral stack. Every accent color answers exactly one operational question.

### Primary
- **Signal Blue** (`#4f8cff`): Interactive elements, focus rings, information-count badges, and the primary action button. The one color a user can act upon.

### Neutral
- **Void Navy** (`#05080f`): The canvas. The entire application sits on top of this. Never used for component backgrounds.
- **Surface** (`#0b1120`): Default component background: sections, table rows, sidebar.
- **Surface Raised** (`#0f1828`): Modals, form panels, elements one level above the main surface.
- **Surface Floating** (`#132035`): Select backgrounds, button fills, elements that appear above raised surfaces.
- **Border Default** (`#1e2d45`): Structural borders, table dividers, card outlines.
- **Border Subtle** (`#172338`): Soft containment borders within a single surface level.
- **Text Primary** (`#e2eaf6`): All body copy, data values, titles. Cold and slightly blue-shifted; never pure white.
- **Text Secondary** (`#94a3b8`): Labels, metadata, nav items at rest, supporting descriptions.
- **Text Muted** (`#566577`): Tertiary information: timestamp annotations, category labels, placeholder text.

### Status Palette (semantic only; never decorative)
- **Heartbeat Green** (`#34d399`): Online agents, successful jobs, clean security posture.
- **Amber Alert** (`#fbbf24`): Stale connections, reboot-pending machines, non-critical warnings.
- **CVE Red** (`#f87171`): Offline agents, unpatched CVE exposure, failed jobs, destructive actions.
- **Approval Violet** (`#a78bfa`): Agents awaiting approval, group membership badges.
- **Action Cyan** (`#22d3ee`): Job action type labels, in-flight operation indicators.

**The State Color Rule.** Every accent color maps to exactly one system state. If you are adding a color that doesn't map to online/success, stale/warning, danger/CVE/failed, approval-pending, or action-in-flight, the element should use `text-secondary` or `border-default` instead.

**The No-Shine Rule.** Glow effects and radial gradient overlays in the current KPI cards are a legacy pattern. Do not extend them. New components use surface layering and borders for depth, not luminosity.

## 3. Typography

**Body Font:** Inter (ui-sans-serif, system-ui, -apple-system, sans-serif)
**Monospace Font:** ui-monospace, SF Mono, Menlo, Consolas, monospace

**Character:** The type system derives its entire personality from weight and spacing contrast. At rest, 13px/400 reads as precise form copy. At emphasis, 30px/800 with -0.06em tracking reads like an altimeter: exact, authoritative, impossible to misread.

### Hierarchy
- **Display** (800, 30px, line-height 1, -0.06em letter-spacing): Operational metric values in overview cards. Not for headings or decorative numbers.
- **Title** (700, 14-15px, line-height 1.3, -0.01 to -0.02em): Section headings, topbar label, modal titles.
- **Body** (400/500, 13px, line-height 1.5): All data content, table cells, form copy, descriptions. Cap at 65ch for any multi-line prose.
- **Label** (700, 10-10.5px, line-height 1.4, 0.08em tracking, uppercase): Column headers, badge text, section category labels, sidebar section dividers.
- **Mono** (400, 11-11.5px, line-height 1.5): Machine IDs, OS version strings, kernel versions, command output logs, install scripts.

**The Weight-Talks Rule.** Hierarchy is never achieved through color alone. Size and weight carry information hierarchy; color carries system state. Keep these responsibilities separated at all times.

## 4. Elevation

PatchPilot uses a hybrid system: four tonal surface steps carry most of the depth, with ambient shadows reinforcing elements that genuinely float above the main plane.

The surface stack (`void-navy` → `surface` → `surface-raised` → `surface-floating`) functions as Z-index made visible. Standard components live at `surface`. Modals live at `surface-raised`. Select menus and button backgrounds live at `surface-floating`. Borders at `border-subtle` delineate containment between components at the same surface level. The sidebar uses a slight transparency with `backdrop-filter: blur(20px)` to layer against main content without a hard edge.

### Shadow Vocabulary
- **Ambient Large** (`0 8px 32px rgba(0,0,0,.45)`): Sections, KPI cards, modals. Deep ambient shadow for elements that should feel fully contained and grounded.
- **Ambient Small** (`0 2px 8px rgba(0,0,0,.3)`): Lighter floating elements. Not currently deployed but available for tooltips or popovers.

**The Flat-at-Rest Rule.** Shadows appear only on components that sit at a raised or floating surface level. Table rows, badges, and inline labels carry no shadows.

**The One-Step Rule.** A component never jumps more than one surface step from its context. A table inside a section lives at `surface`; the section container itself also lives at `surface`. A modal lives at `surface-raised`. A dropdown from within a modal lives at `surface-floating`. Never skip a step.

## 5. Components

### Buttons
Functional at rest, the primary variant is the only element with a gradient fill.
- **Shape:** Gently rounded (8px) across all variants.
- **Primary:** Blue-to-violet linear gradient (`#2563eb` → `#7c3aed`) with a `rgba(255,255,255,.1)` border. This is the only gradient in the system. Padding 6px 12px; small variant 4px 9px.
- **Default:** `surface-floating` background, `border-default` border. Hover: border shifts to `rgba(79,140,255,.4)`.
- **Danger:** Dark red background (`rgba(127,29,29,.7)`), `accent-danger` text. Reserved for irreversible destructive actions: delete machine, reject agent.
- **Ghost:** Transparent background, transparent border, `text-secondary`. For auxiliary low-priority actions in dense contexts.
- **Known gap:** No `:active` scale state is currently implemented. All variants require `transform: scale(0.97)` on `:active` and should be gated behind `@media (hover: hover) and (pointer: fine)` for hover states.

### Badges
The semantic state system made tangible. All badges are pill-shaped (999px radius), always paired with a dim background at approximately 12% opacity of the accent color and an explicit border at approximately 25% opacity.
- **ok / green:** Online agents, succeeded jobs.
- **bad / red:** Failed jobs, offline agents, CVE severity flags.
- **warn / yellow:** Stale connections, reboot-pending state.
- **info / blue:** Informational count chips, detail labels.
- **disabled / gray:** Inactive states, non-actionable entities.
- **purple:** Pending-approval agents, group membership.
- **cyan:** Job action type labels.

Badge text: 10.5px/700, uppercase, 0.04em tracking. Badge pairs with a status dot when conveying connectivity state.

### Status Dots
7px circles. Online dots pulse continuously (opacity 1 → 0.55, scale 1 → 0.8, 2s ease infinite). Stale and offline dots are static. The pulse animation must be disabled for `prefers-reduced-motion`.

### Navigation (Sidebar)
Sidebar is 240px wide, sticky, with `backdrop-filter: blur(20px)`. Nav links are 8px 10px padding, 8px radius, transparent background at rest. Hover: `rgba(255,255,255,.05)` background with `border-subtle` border. Icon opacity: 75% at rest, 100% on hover. No active-state implementation yet; pages use anchor-based section navigation.

### Tables
Full-width with `border-collapse`. Column headers: 10.5px/700/uppercase, `text-muted`, with a `border-subtle` bottom rule. Cell padding: 11px 14px vertically. Row hover: `rgba(255,255,255,.015)` background, the lowest noticeable value above zero.

**Current violation:** CVE-risk rows use `border-left: 2px solid rgba(248,113,113,.4)` as a scan-line indicator. This conflicts with the side-stripe ban. The correct treatment is a full-row background tint: `background: rgba(248,113,113,.05)` on affected `<tr>`. Fix during a future refactor pass.

### Inputs and Search
All inputs: `surface-floating` background, `border-default` border, 8px radius. Focus: border shifts to `rgba(79,140,255,.6)` with 3px outer glow in `rgba(79,140,255,.12)`. The search input has a 14px leading icon with 32px left padding compensation.

### Section Containers
The primary content grouping unit. `surface` background, `border-subtle` border, 16px radius, `ambient-large` shadow. Section headers carry a subtle top-to-transparent gradient overlay (`rgba(255,255,255,.03)` to transparent). Actions align right. Section containers are never nested inside other section containers.

### Modal
Single centered dialog. `surface-raised` background, `border-default` border, 16px radius, `ambient-large` shadow. Backdrop: `rgba(0,0,0,.65)` with `blur(4px)`. Currently opens with no transition; the modal and backdrop need `opacity` + `transform: scale(0.96→1)` enter animation at 200ms ease-out. Modal scales from center; `transform-origin: center` is correct here (not trigger-anchored, unlike popovers).

## 6. Do's and Don'ts

### Do:
- **Do** use exact values for all data: full timestamps, integer counts, literal version strings. Approximate language ("recently", "a few") is prohibited in the UI layer.
- **Do** bind each accent color to exactly one system state. Green for online/success only. Red for danger/CVE/failed only. Any deviation breaks the State Color Rule.
- **Do** cap body-level prose at 65ch line length for any text longer than one line.
- **Do** use monospace for all machine identifiers, OS version strings, kernel versions, command output, and install scripts.
- **Do** implement `prefers-reduced-motion`: suppress the status-dot pulse animation and all transition-based motion for users who request it.
- **Do** gate hover state CSS behind `@media (hover: hover) and (pointer: fine)` across all interactive elements.
- **Do** add `transform: scale(0.97)` on `:active` to every button variant before shipping any new UI.
- **Do** use WCAG 2.1 AA contrast (4.5:1 minimum) for all text against its background, including badge text on its dim background.

### Don't:
- **Don't** use gradient text (`background-clip: text` with a gradient). Emphasis via weight or size only; color is for state.
- **Don't** extend the KPI card glow/gradient overlay pattern to new components. It is a legacy pattern and should not propagate. New metric readouts use surface layering and borders only.
- **Don't** add new `border-left` or `border-right` side-stripe accents. The CVE-risk row border is a known violation; replace it with a full-row background tint during refactor.
- **Don't** build shiny SaaS dashboards: no Mixpanel/Amplitude-style glowing card grids, no gradient-accented big-number hero metrics, no "insight" copy that restates what the number says.
- **Don't** use glassmorphism decoratively. Backdrop blur appears only in the sidebar and topbar, where it serves structural layering. New components do not add blur for atmosphere.
- **Don't** use color for decoration. If a color choice cannot be explained by answering "what system state does this communicate," it is wrong.
- **Don't** animate keyboard-triggered or high-frequency actions. Filter search, form submits, and sidebar navigation carry no animation.
- **Don't** nest section containers. A `.section` never appears inside another `.section`.
- **Don't** introduce a new accent color. The six-color state vocabulary is closed. If a new state requires a new color, the existing palette must first be audited for overload.
