# Launch checklist (every product of Ebda AI Studio)

- [ ] Legal pages live (terms, privacy, DPA) with provisional markers resolved
- [ ] Alerts tested end to end (a deliberate alert reaches Telegram and Sentry, phones masked)
- [ ] Logpush enabled, retention >= 30 days
- [ ] Backup drill done (restore proven, not assumed)
- [ ] Feature flags default off; each flipped only after its proof
- [ ] Erasure drill: every table or column holding a phone or buyer key is in the erasure registry
- [ ] Deploy-verify green: deploy job, `/health` commit = main, live cron schedules match wrangler, one tick seen
- [ ] Status-page probe added
- [ ] `npm audit` 0, gitleaks green, foundation parity green
