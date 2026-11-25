# Windows Notes

- Hooks and the Bash tool run in Git Bash: use POSIX shell syntax and forward slashes, and
  convert paths with `cygpath` when a native Windows tool needs them.
- Quote every path: Windows user directories often contain spaces (`C:\Users\First Last`).
- Keep shell scripts on LF line endings (a `.gitattributes` rule such as `*.sh text eol=lf`);
  a script checked out with CRLF fails in Bash with `$'\r': command not found`.
