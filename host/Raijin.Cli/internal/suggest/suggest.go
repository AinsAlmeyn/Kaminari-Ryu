// Package suggest offers a "did you mean?" helper with a stricter
// admission rule than plain Levenshtein: a candidate is eligible only if
// it looks meaningfully related to what the user typed. Random strings
// like "xyz" won't resurrect "doom" just because four edits happen to
// fit in the max-distance budget.
package suggest

import "sort"

// Closest returns up to maxResults candidates, ranked by similarity.
// The admission rule is:
//
//   1. prefix match  → always included  (weight 0 + prefix bonus)
//   2. substring     → included          (weight 1)
//   3. edit distance ≤ ceil(len(typed)/2)+1  AND  ≤ 3    → included
//
// Everything else is silently dropped. This keeps the suggestion panel
// honest: "dom" suggests "doom", "xyz" suggests nothing.
func Closest(typed string, candidates []string, maxResults, _ int) []string {
	if typed == "" {
		return nil
	}
	t := lower(typed)

	// Cap the allowed edit distance at something proportional to what
	// the user actually typed. For "dom" (3 chars) we allow up to 2
	// edits, which covers all realistic typos without pulling in
	// random strings.
	distBudget := len(t)/2 + 1
	if distBudget > 3 {
		distBudget = 3
	}
	if distBudget < 1 {
		distBudget = 1
	}

	type scored struct {
		name  string
		score int
	}
	var out []scored

	for _, c := range candidates {
		lc := lower(c)

		// Rule 1: prefix.
		if hasPrefix(lc, t) {
			out = append(out, scored{c, -2})
			continue
		}
		// Rule 2: substring.
		if contains(lc, t) {
			out = append(out, scored{c, 1})
			continue
		}
		// Rule 3: edit distance within a tight budget.
		if d := levenshtein(t, lc); d <= distBudget {
			out = append(out, scored{c, d})
		}
	}

	sort.SliceStable(out, func(i, j int) bool {
		if out[i].score != out[j].score {
			return out[i].score < out[j].score
		}
		return out[i].name < out[j].name
	})
	if len(out) > maxResults {
		out = out[:maxResults]
	}
	names := make([]string, len(out))
	for i, s := range out {
		names[i] = s.name
	}
	return names
}

func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

func hasPrefix(s, p string) bool {
	if len(p) > len(s) {
		return false
	}
	return s[:len(p)] == p
}

func contains(s, sub string) bool {
	if len(sub) > len(s) {
		return false
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func levenshtein(a, b string) int {
	if len(a) == 0 {
		return len(b)
	}
	if len(b) == 0 {
		return len(a)
	}
	prev := make([]int, len(b)+1)
	curr := make([]int, len(b)+1)
	for j := 0; j <= len(b); j++ {
		prev[j] = j
	}
	for i := 1; i <= len(a); i++ {
		curr[0] = i
		for j := 1; j <= len(b); j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			curr[j] = min3(curr[j-1]+1, prev[j]+1, prev[j-1]+cost)
		}
		prev, curr = curr, prev
	}
	return prev[len(b)]
}

func min3(a, b, c int) int {
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}
