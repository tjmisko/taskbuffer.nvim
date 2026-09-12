" Taskbuffer renders visible text; source metadata is stored in Lua.
syntax match taskfileTag /\v#[A-Za-z_\-]+/
syntax match taskfileHeading /^# .*/
syntax match taskfileOverdue /^# Overdue.*/
syntax match taskfileDeferral /::deferral/
syntax match taskfileOriginal /::original/
syntax match taskfileComplete /::complete/
syntax match taskfileDate /\v[0-9]{4}-[0-9]{2}-[0-9]{2}/
syntax match taskfileTime /\v[0-9]{2}:[0-9]{2}/
syntax match taskfileDuration /\v[0-9]+m/
