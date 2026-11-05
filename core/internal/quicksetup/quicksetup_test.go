package quicksetup

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
	"testing"
)

func TestActualStagesAndClosedErrors(t *testing.T) {
	cases := []struct {
		name   string
		decode func() error
		init   func() bool
		setup  func() error
		apply  func() error
		want   string
	}{
		{"initdecode", func() error { return errors.New("PRIVATE_PATH") }, nil, nil, nil, "@CA1:1:1:0"},
		{"initfalse", nil, func() bool { return false }, nil, nil, "@CA1:2:0:0"},
		{"setupdecode", nil, nil, func() error { return errors.New("PRIVATE_YAML") }, nil, "@CA1:3:1:0"},
		{"configapply", nil, nil, nil, func() error { return &os.PathError{Op: "open", Path: "PRIVATE_PATH", Err: syscall.EACCES} }, "@CA1:4:2:13"},
		{"panic", nil, nil, nil, func() error { panic("PRIVATE_PANIC") }, "@CA1:5:3:0"},
		{"success", nil, nil, nil, nil, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			decode := c.decode
			if decode == nil {
				decode = func() error { return nil }
			}
			init := c.init
			if init == nil {
				init = func() bool { return true }
			}
			setup := c.setup
			if setup == nil {
				setup = func() error { return nil }
			}
			apply := c.apply
			if apply == nil {
				apply = func() error { return nil }
			}
			got := Run(decode, init, setup, apply)
			if got != c.want {
				t.Fatalf("got %q want %q", got, c.want)
			}
			if strings.Contains(got, "PRIVATE") {
				t.Fatal("private data escaped")
			}
		})
	}
}
func TestRealOpenError(t *testing.T) {
	_, err := os.Open(t.TempDir() + "/absent")
	got := Run(func() error { return nil }, func() bool { return true }, func() error { return nil }, func() error { return fmt.Errorf("private wrapper: %w", err) })
	if got != "@CA1:4:2:2" {
		t.Fatal(got)
	}
}
func TestNoSubstringErrno(t *testing.T) {
	got := Run(func() error { return nil }, func() bool { return true }, func() error { return nil }, func() error { return errors.New("permission denied errno=13 PRIVATE") })
	if got != "@CA1:4:1:0" {
		t.Fatal(got)
	}
}
