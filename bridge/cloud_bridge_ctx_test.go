package bridge

import (
	"context"
	"testing"
	"time"
)

func TestOpCtxAppliesTimeoutWithoutAppCtx(t *testing.T) {
	a := &App{} // Ctx is nil (headless / pre-startup)
	ctx, cancel := a.opCtx(50 * time.Millisecond)
	defer cancel()
	if _, ok := ctx.Deadline(); !ok {
		t.Fatal("opCtx must apply a deadline even when a.Ctx is nil")
	}
}

func TestOpCtxCancelsWithAppLifecycle(t *testing.T) {
	parent, cancelParent := context.WithCancel(context.Background())
	a := &App{Ctx: parent}

	ctx, cancel := a.opCtx(time.Minute)
	defer cancel()

	// Cancelling the app lifecycle context must propagate to the operation
	// context, so an in-flight cloud call aborts on shutdown.
	cancelParent()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("operation context did not cancel when the app context was cancelled")
	}
}
