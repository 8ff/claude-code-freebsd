# claude-code-freebsd

Tiny install script that sets up [Claude Code](https://github.com/anthropics/claude-code) on **FreeBSD** by running Anthropic's own Linux x64 binary under [Linuxulator](https://docs.freebsd.org/en/books/handbook/linuxemu/). This is just an automated version of the workaround Anthropic's [ant-kurt posted](https://github.com/anthropics/claude-code/issues/30640#issuecomment-4088522223) on issue #30640:

> Starting with Claude Code 2.1.101, you can run Claude Code under Linuxulator with this additional env var: `BUN_JSC_useBBQJIT=0 claude`.

**This is a temporary workaround.** The real fix is a native FreeBSD Bun build (work-in-progress upstream at [oven-sh/bun#1524](https://github.com/oven-sh/bun/issues/1524) / [lwhsu/bun's `claude/freebsd-support` branch](https://github.com/lwhsu/bun/tree/claude/freebsd-support)). Once that lands, this repo becomes obsolete.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/8ff/claude-code-freebsd/main/install.sh | sh
```

Tested on FreeBSD 15 amd64. Should also work on FreeBSD 13.2+ / 14.x amd64 as long as `linux_base-rl9` (glibc 2.34) is in your pkg repo — older `linux_base-c7` (glibc 2.17) is too old for Bun's Linux binary. On first run, if Linuxulator isn't fully set up, the script prints the `doas` commands you need to run and exits; it never runs privileged commands on your behalf. On every supported release, including 15, expect to need all four: `doas kldload linux64`, `doas sysrc linux_enable="YES"`, `doas pkg install -y linux_base-rl9`, `doas service linux start`. The GENERIC kernel does not build the Linux ABI in (verified on 15.1-RELEASE GENERIC: `sysctl kern.conftxt` lists `COMPAT_LINUXKPI` only, and `compat.linux.osrelease` is an unknown oid until `linux64` is loaded). The script detects which steps are missing and prints only those.

The script downloads `~230 MB` from Anthropic's CDN, verifies sha256 against their signed manifest, installs the binary to `~/.local/share/claude/claude-linux-x64`, and drops a wrapper at `~/.local/bin/claude` that sets `BUN_JSC_useBBQJIT=0` automatically.

After install, open a new shell and run `claude`.

## Uninstall

```sh
rm -f ~/.local/bin/claude ~/.local/share/claude/claude-linux-x64
rm -rf ~/.claude ~/.claude.json ~/.cache/claude-cli-nodejs
```

## Not redistributed

Anthropic's Claude Code binary is their proprietary software and is **not** stored in this repo. The install script downloads it directly from Anthropic's own CDN at install time. Use is subject to [Anthropic's Commercial Terms](https://www.anthropic.com/legal/commercial-terms).

The scripts and docs in this repo are GPL v3 ([LICENSE](LICENSE)).

## Credit

- [ant-kurt](https://github.com/ant-kurt) at Anthropic — for publishing the `BUN_JSC_useBBQJIT=0` flag on issue #30640. This repo exists because of that comment.
- [Li-Wen Hsu (@lwhsu)](https://github.com/lwhsu) — for driving the actual native port upstream.
