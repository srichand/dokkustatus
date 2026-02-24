# TODO

- [ ] Improve SSH/Dokku error reporting for `sudo`/TTY failures.
  - Detect common stderr patterns such as:
    - `sudo: a terminal is required to read the password`
    - `sudo: a password is required`
  - Show a clearer user-facing message explaining that Dokku commands are run non-interactively over SSH and the selected SSH user likely cannot run Dokku without interactive sudo.
  - Include suggested fixes in the UI error text:
    - Select a different profile (e.g., `dokku`/`root` or a user with direct Dokku permissions).
    - Verify the selected host alias in `~/.ssh/config` is not forcing a `sudo` remote command.
    - Test manually with `ssh <host-or-alias> "dokku apps:list"`.
