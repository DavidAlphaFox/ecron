-define(Job, ecron_job).
-define(Ecron, ecron).

-define(MAX_TIMEOUT, 4294967). %% (16#ffffffff div 1000) 49.71 days.
-define(Success, [ecron, success]).
-define(Failure, [ecron, failure]).
-define(Activate, [ecron, activate]).
-define(Deactivate, [ecron, deactivate]).
-define(Delete, [ecron, delete]).