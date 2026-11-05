// Package quicksetup runs the real bridge stages without retaining raw errors.
// @CA1:stage:kind:errno is an additive closed failure prefix; success stays empty.
package quicksetup

import (
	"errors"
	"fmt"
	"syscall"
)

func failure(stage int, err error) string {
	kind, code := 0, 0
	if err != nil {
		kind = 1
		var n syscall.Errno
		if errors.As(err, &n) {
			kind = 2
			switch n {
			case syscall.ENOENT: code = 2
			case syscall.EACCES: code = 13
			case syscall.EPERM: code = 1
			case syscall.ENOTDIR: code = 20
			case syscall.EIO: code = 5
			case syscall.EMFILE: code = 24
			case syscall.ENFILE: code = 23
			}
		}
	}
	return fmt.Sprintf("@CA1:%d:%d:%d", stage, kind, code)
}

func Run(decode func() error, initialize func() bool, setupDecode func() error, apply func() error) (result string) {
	defer func() {
		if recover() != nil {
			result = "@CA1:5:3:0"
		}
	}()
	if err := decode(); err != nil {
		return failure(1, err)
	}
	if !initialize() {
		return failure(2, nil)
	}
	if err := setupDecode(); err != nil {
		return failure(3, err)
	}
	if err := apply(); err != nil {
		return failure(4, err)
	}
	return ""
}
