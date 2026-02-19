syntax match taskfileFilepath /^\/[^\t]*/ conceal
syntax match taskfileTab /\t/ conceal
syntax match taskfileTag /\v#[A-Za-z_\-]+/
syntax region taskfileHeading matchgroup=taskfileHeadingDelimiter start=/^\s*#\s/ end=/\n/ contains=markdownH1Text concealends
syntax region taskfileOverdue matchgroup=taskfileHeadingDelimiter start=/^\s*# Overdue\s/ end=/\n/ contains=markdownH1Text concealends
syntax match taskfileDeferral /\:\:deferral/
syntax match taskfileOriginal /\:\:original/
syntax match taskfileComplete /\:\:complete/
syntax match taskfileOpenLink /\[\[/ conceal
syntax match taskfileCloseLink /\]\]/ conceal
syntax match taskfileDate /[0-9]{4}-[0-9]{2}-[0-9]{2}/
syntax match taskfileTime /[0-9]{2}\:[0-9]{2}/
syntax match taskfileDuration /[0-9]{2}m/
