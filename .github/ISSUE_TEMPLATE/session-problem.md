---
name: RDP session problem
about: A session will not start, dies, or misbehaves
labels: session
---

## What happens

<!-- e.g. "login box accepts the password, then the screen stays black" -->

## Doctor output

Please paste the full output. It is read-only and safe to run.

```
$ sudo kali-rdp-doctor
```

<details>
<summary>output</summary>

```
paste here
```

</details>

## Environment

```
$ cat /etc/os-release | head -3
$ dpkg-query -W -f='${Version}\n' xrdp kali-rdp-kit
$ kali-rdp-profile show
```

## If the session starts and then dies

How many seconds does it survive? A consistent interval points at a timeout
rather than a crash, and that is a very different bug — please say whether the
timing is consistent across attempts.

```
$ sudo tail -50 /var/log/xrdp-sesman.log
```
