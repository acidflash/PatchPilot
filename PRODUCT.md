# Product

## Register

product

## Users

Sysadmins and DevOps engineers managing fleets of Ubuntu servers. They check this at odd hours, often under pressure: a CVE just dropped, a cron job failed, a server hasn't checked in. They know what they're doing; they don't need hand-holding. The primary task on any given session is answering one of three questions: is everything patched, is anything broken, what needs my attention right now.

## Product Purpose

PatchPilot is self-hosted patch management for Ubuntu server fleets. Agents on each machine report in, receive commands, and execute controlled updates. The web UI is the control center: operators see the full fleet state, queue jobs, manage schedules, and approve or reject agent enrollments. The product exists to make patch compliance boring: the right patches applied on the right schedule, with a clear audit trail, and no surprises.

## Brand Personality

Precise, calm, trusted. The interface should feel like a well-maintained server room: no noise, no drama, no decoration that doesn't earn its place. Confidence comes from clarity, not from visual energy.

## Anti-references

- **Shiny SaaS dashboards**: Mixpanel, Amplitude, Datadog's marketing pages. No glow on every card, no gradient hero metrics, no big-number-with-accent-bar KPI templates, no "insight" copy that restates what the number already says.
- No decorative glassmorphism, translucent layering used for atmosphere rather than structure.
- No color-for-color's-sake: every color token must answer "what state does this communicate."

## Design Principles

1. **Information over decoration.** If a visual element doesn't communicate data or hierarchy, it shouldn't be there. Ornamentation is a tax on the operator's attention.
2. **Calm confidence, not alarm theater.** Warnings are precise and legible, not emotionally charged. A red badge means "act on this"; not "panic." The interface should feel stable even when there are problems.
3. **Trust through precision.** Exact numbers, exact timestamps, exact states. No rounding, no approximations, no vague copy like "recently" or "a few updates."
4. **Optimized for return visits, not first impressions.** This is a tool opened many times per week by the same person. Clarity and speed matter more than onboarding charm.
5. **Security posture is visible without being theatrical.** CVE exposure, unapproved agents, pending reboots should surface naturally in the hierarchy, not require hunting.

## Accessibility & Inclusion

WCAG 2.1 AA. Minimum 4.5:1 text contrast, keyboard navigable for all critical actions (approve, queue job, disable machine), `prefers-reduced-motion` respected, screen reader compatible for status regions.
