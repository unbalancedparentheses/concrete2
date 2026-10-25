### Bug 264: isolate the work-queue dependent-dispatch test

Reconcile a completed fake agent with dispatch disabled before simulating its landing. Assert
the worker slot is empty, then enable dispatch and check that its dependent starts. Previously
an unrelated ready task could correctly occupy that slot and fail the assertion. Scheduler
behavior is unchanged.
