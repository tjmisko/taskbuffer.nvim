" Taskbuffer renders visible text; source metadata is stored in Lua.
syntax match taskfileTag /\v#[A-Za-z_\-]+/
syntax match taskfileHeading /^# .*/
syntax match taskfileOverdue /^# Overdue.*/
syntax match taskfileDeferral /::deferral/
syntax match taskfileOriginal /::original/
syntax match taskfileComplete /::complete/
