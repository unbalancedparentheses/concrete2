### Bug 264: isolate the work-queue dependent-dispatch test

Reconcile a completed fake agent with dispatch disabled, then explicitly test pre-landing
dispatch: unrelated work starts while the dependent remains blocked. Release the unrelated
work before simulating landing and checking that the dependent starts. Previously that work
could correctly occupy the only slot and fail the assertion. Scheduler behavior is unchanged.
