package main

import (
	"regexp"
	"strings"
)

// DateTimeFormats holds Go layout strings and regex patterns derived from
// strftime-style format strings (e.g. "%Y-%m-%d").
type DateTimeFormats struct {
	GoDate string // e.g. "2006-01-02" or "01/02/2006"
	GoTime string // e.g. "15:04" or "3:04 PM"
	DateRe string // e.g. `\d{4}-\d{2}-\d{2}` or `\d{2}/\d{2}/\d{4}`
	TimeRe string // e.g. `\d{2}:\d{2}` or `\d{1,2}:\d{2}\s*[AaPp][Mm]`
}

// strftime directive -> Go reference layout component
var strftimeToGoMap = map[string]string{
	"%Y": "2006",
	"%m": "01",
	"%d": "02",
	"%H": "15",
	"%M": "04",
	"%I": "3",
	"%p": "PM",
	"%F": "2006-01-02",
	"%R": "15:04",
}

// strftime directive -> regex pattern
var strftimeToReMap = map[string]string{
	"%Y": `\d{4}`,
	"%m": `\d{2}`,
	"%d": `\d{2}`,
	"%H": `\d{2}`,
	"%M": `\d{2}`,
	"%I": `\d{1,2}`,
	"%p": `[AaPp][Mm]`,
	"%F": `\d{4}-\d{2}-\d{2}`,
	"%R": `\d{2}:\d{2}`,
}

// StrftimeToGo converts a strftime format string to a Go time.Parse layout.
func StrftimeToGo(strftime string) string {
	if strftime == "" {
		return ""
	}
	return convertStrftime(strftime, strftimeToGoMap, false)
}

// StrftimeToRegex converts a strftime format string to a regex pattern.
func StrftimeToRegex(strftime string) string {
	if strftime == "" {
		return ""
	}
	return convertStrftime(strftime, strftimeToReMap, true)
}

// convertStrftime walks the format string, replacing known directives and
// handling literals (with optional regex escaping).
func convertStrftime(format string, table map[string]string, escLiterals bool) string {
	var b strings.Builder
	i := 0
	for i < len(format) {
		if format[i] == '%' && i+1 < len(format) {
			next := format[i+1]
			if next == '%' {
				// Escaped percent
				if escLiterals {
					b.WriteString(regexp.QuoteMeta("%"))
				} else {
					b.WriteByte('%')
				}
				i += 2
				continue
			}
			directive := format[i : i+2]
			if replacement, ok := table[directive]; ok {
				// In regex mode, collapse whitespace before %p into \s*
				if escLiterals && directive == "%p" {
					s := b.String()
					if strings.HasSuffix(s, " ") {
						b.Reset()
						b.WriteString(s[:len(s)-1])
						b.WriteString(`\s*`)
					}
				}
				b.WriteString(replacement)
				i += 2
				continue
			}
			// Unknown directive: pass through literally
			if escLiterals {
				b.WriteString(regexp.QuoteMeta(directive))
			} else {
				b.WriteString(directive)
			}
			i += 2
			continue
		}
		// Literal character
		if escLiterals {
			b.WriteString(regexp.QuoteMeta(string(format[i])))
		} else {
			b.WriteByte(format[i])
		}
		i++
	}
	return b.String()
}

// ResolveDateTimeFormats returns a DateTimeFormats with Go layouts and regex
// patterns. Empty inputs default to ISO 8601 ("%Y-%m-%d" / "%H:%M").
func ResolveDateTimeFormats(dateFmt, timeFmt string) DateTimeFormats {
	if dateFmt == "" {
		dateFmt = "%Y-%m-%d"
	}
	if timeFmt == "" {
		timeFmt = "%H:%M"
	}
	return DateTimeFormats{
		GoDate: StrftimeToGo(dateFmt),
		GoTime: StrftimeToGo(timeFmt),
		DateRe: StrftimeToRegex(dateFmt),
		TimeRe: StrftimeToRegex(timeFmt),
	}
}
