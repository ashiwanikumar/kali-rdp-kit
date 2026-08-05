---
name: Bug report
about: One of the tools did the wrong thing
labels: bug
---

## What you ran

```
$ sudo kali-rdp-... 
```

## What you expected, and what happened instead

## Was anything killed that should not have been?

If `kali-rdp-cleanup` reaped a session you were using, this is high priority —
please include:

```
$ sudo kali-rdp-cleanup --dry-run --verbose
$ cat /var/lib/kali-rdp-kit/disconnected.state
```

## Version

```
$ dpkg-query -W -f='${Version}\n' kali-rdp-kit
```
