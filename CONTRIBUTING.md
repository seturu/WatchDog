# Contributing to WatchDog

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Before you change enforcement code

WatchDog runs a root daemon that edits `/etc/hosts`, the packet filter and browser policies. A bug there can lock someone out of their own Mac, so:

- Work in the **development build** (Debug). It has its own identity and hard safety caps: 5-minute blocks, only `example.com` / `.org` / `.net`, and a daemon that resets itself every 15 minutes. Don't loosen those caps in a pull request.
- Every new thing the daemon changes on the system needs its undo in `scripts/uninstall.sh` and `docs/RESCUE.md`, in the same pull request.
- Run the core tests: `swift test --package-path Packages/WatchDogCore`. New logic in `WatchDogCore` should come with tests.
- Say in the pull request what you ran live and what you only compiled.

Build setup is in the [README](README.md#install). Your team ID goes in `Config/Local.xcconfig`, which git ignores; never commit it.

## Security problems

Please don't open a public issue for a way around the daemon's protections or anything that could harm a user's system. Use **Security → Report a vulnerability** on the repository page instead.

## Licensing of contributions

WatchDog is licensed under the [GNU General Public License v3.0 or later](LICENSE). By submitting a contribution (a pull request, patch or code in an issue), you agree that:

1. your contribution is licensed under GPL-3.0-or-later, like the rest of WatchDog;
2. you also grant the maintainer a perpetual, worldwide, non-exclusive, royalty-free license to use, modify and distribute your contribution under other terms, including commercial licenses. This keeps it possible to offer WatchDog to companies under a separate license and fund its development. You keep the copyright to your work, and WatchDog stays available under the GPL;
3. you have the right to submit it: it is your own work, or you have permission, and it does not include code under a license incompatible with the above.

If you can't agree to point 2, say so in the pull request before it is merged.
