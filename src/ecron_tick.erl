%%% @private
-module(ecron_tick).
-include("ecron.hrl").
-export([add/2, delete/1]).
-export([activate/1, deactivate/1]).
-export([statistic/1, statistic/0]).
-export([reload/0]).
-export([predict_datetime/2]).

-export([start_link/1, handle_call/3, handle_info/2, init/1, handle_cast/2]).
-export([spawn_mfa/3, clear/0]).

-record(state, {time_zone, max_timeout, timer_tab, job_tab = ?Job}).
-record(job, {name, status = activate, job, opts = [], ok = 0, failed = 0,
    link = undefined, result = [], run_microsecond = []}).
-record(timer, {key, name, cur_count = 0, singleton, type, spec, mfa, link,
    start_sec = unlimited, end_sec = unlimited, max_count = unlimited}).

-define(MAX_SIZE, 16).
-define(SECONDS_FROM_0_TO_1970, 719528 * 86400).
-define(day_of_week(Y, M, D), (case calendar:day_of_the_week(Y, M, D) of 7 -> 0; D1 -> D1 end)).
-define(MatchSpec(Name), [{#timer{name = '$1', _ = '_'}, [], [{'=:=', '$1', {const, Name}}]}]).

add(Job, Options) -> gen_server:call(?Ecron, {add, Job, Options}, infinity).
delete(Name) -> gen_server:call(?Ecron, {delete, Name}, infinity).
activate(Name) -> gen_server:call(?Ecron, {activate, Name}, infinity).
deactivate(Name) -> gen_server:call(?Ecron, {deactivate, Name}, infinity).
get_next_schedule_time(Name) -> gen_server:call(?Ecron, {next_schedule_time, Name}, infinity).
clear() -> gen_server:call(?Ecron, clear, infinity).
reload() -> gen_server:cast(?Ecron, reload).

statistic(Name) ->
    case ets:lookup(?Job, Name) of
        [Job] -> {ok, job_to_statistic(Job)};
        [] ->
            try
                gen_server:call({global, ?Ecron}, {statistic, Name})
            catch _:_ ->
                {error, not_found}
            end
    end.

statistic() ->
    Local = ets:foldl(fun(Job, Acc) -> [job_to_statistic(Job) | Acc] end, [], ?Job),
    Global =
        try
            gen_server:call({global, ?Ecron}, statistic)
        catch _:_ ->
            []
        end,
    Local ++ Global.

predict_datetime(Job, Num) ->
    TZ = get_time_zone(),
    Now = current_millisecond(),
    predict_datetime(activate, Job, unlimited, unlimited, Num, TZ, Now).

start_link(Name) -> gen_server:start_link(Name, ?MODULE, [Name], []).

init([{Type, _}]) ->
    erlang:process_flag(trap_exit, true),
    TZ = get_time_zone(),
    Tab = ets:new(ecron_timer, [ordered_set, private, {keypos, #timer.key}]),
    MaxTimeout = application:get_env(?Ecron, adjusting_time_second, 7 * 24 * 3600) * 1000,
    init(Type, TZ, MaxTimeout, Tab).

handle_call({add, Job, Options}, _From, State) ->
    #state{time_zone = TZ, timer_tab = Tab, job_tab = JobTab} = State,
    {reply, add_job(JobTab, Tab, Job, TZ, Options, false), State, tick(State)};

handle_call({delete, Name}, _From, State = #state{timer_tab = Tab, job_tab = JobTab}) ->
    delete_job(JobTab, Tab, Name),
    {reply, ok, State, next_timeout(State)};

handle_call({activate, Name}, _From, State) ->
    #state{job_tab = JobTab, time_zone = TZ, timer_tab = TimerTab} = State,
    {reply, activate_job(JobTab, Name, TZ, TimerTab), State, tick(State)};

handle_call({deactivate, Name}, _From, State) ->
    #state{timer_tab = TimerTab, job_tab = JobTab} = State,
    {reply, deactivate_job(JobTab, Name, TimerTab), State, next_timeout(State)};

handle_call({statistic, Name}, _From, State) ->
    Res = job_to_statistic(Name, State),
    {reply, Res, State, next_timeout(State)};

handle_call(statistic, _From, State = #state{timer_tab = Timer}) ->
    Res =
        ets:foldl(fun(#timer{name = Name}, Acc) ->
            {ok, Item} = job_to_statistic(Name, State),
            [Item | Acc]
                  end, [], Timer),
    {reply, Res, State, next_timeout(State)};

handle_call({next_schedule_time, Name}, _From, State = #state{timer_tab = Timer}) ->
    {reply, get_next_schedule_time(Timer, Name), State, next_timeout(State)};

handle_call(clear, _From, State = #state{timer_tab = Timer}) ->
    ets:delete_all_objects(Timer),
    ets:delete_all_objects(?Job),
    {reply, ok, State, next_timeout(State)};

handle_call(_Unknown, _From, State) ->
    {noreply, State, next_timeout(State)}.

handle_info(timeout, State) ->
    {noreply, State, tick(State)};

handle_info({'EXIT', Pid, _Reason}, State = #state{timer_tab = TimerTab}) ->
    pid_delete(Pid, TimerTab),
    {noreply, State, next_timeout(State)};

handle_info(_Unknown, State) ->
    {noreply, State, next_timeout(State)}.

handle_cast(_Unknown, State) ->
    {noreply, State, next_timeout(State)}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

init(local, TZ, MaxTimeout, Tab) ->
    case parse_crontab(local_jobs(), []) of
        {ok, Jobs} ->
            [begin ets:insert_new(?Job, Job) end || Job <- Jobs],
            [begin add_job(?Job, Tab, Job, TZ, Opts, true)
             end || #job{job = Job, opts = Opts, status = activate} <- ets:tab2list(?Job)],
            State = #state{max_timeout = MaxTimeout, time_zone = TZ, timer_tab = Tab, job_tab = ?Job},
            {ok, State, next_timeout(State)};
        Reason -> Reason
    end;
init(global, TZ, MaxTimeout, Tab) ->
    case parse_crontab(global_jobs(), []) of
        {ok, Jobs} ->
            ?GlobalJob = ets:new(?GlobalJob, [named_table, set, public, {keypos, 2}]),
            [begin add_job(?GlobalJob, Tab, Job, TZ, Opts, true)
             end || #job{job = Job, opts = Opts, status = activate} <- Jobs],
            State = #state{max_timeout = MaxTimeout, time_zone = TZ, timer_tab = Tab, job_tab = ?GlobalJob},
            {ok, State, next_timeout(State)};
        Reason -> Reason
    end.

parse_crontab([], Acc) -> {ok, Acc};
parse_crontab([{Name, Spec, {_M, _F, _A} = MFA} | Jobs], Acc) ->
    parse_crontab([{Name, Spec, {_M, _F, _A} = MFA, unlimited, unlimited, []} | Jobs], Acc);
parse_crontab([{Name, Spec, {_M, _F, _A} = MFA, Start, End} | Jobs], Acc) ->
    parse_crontab([{Name, Spec, {_M, _F, _A} = MFA, Start, End, []} | Jobs], Acc);
parse_crontab([{Name, Spec, {_M, _F, _A} = MFA, Start, End, Opts} | Jobs], Acc) ->
    case parse_job(Name, Spec, MFA, Start, End, Opts) of
        {ok, Job} -> parse_crontab(Jobs, [Job | Acc]);
        {error, Field, Reason} -> {stop, lists:flatten(io_lib:format("~p: ~p", [Field, Reason]))}
    end;
parse_crontab([L | _], _Acc) -> {stop, L}.

parse_job(JobName, Spec, MFA, Start, End, Opts) ->
    case ecron:valid_datetime(Start, End) of
        true ->
            case ecron:parse_spec(Spec) of
                {ok, Type, Crontab} ->
                    Job = #{type => Type, name => JobName, crontab => Crontab, mfa => MFA,
                        start_time => Start, end_time => End},
                    {ok, #job{name = JobName,
                        status = activate, job = Job,
                        opts = valid_opts(Opts),
                        link = link_pid(MFA)}};
                ErrParse -> ErrParse
            end;
        false ->
            {error, invalid_time, {Start, End}}
    end.

add_job(JobTab, Tab, #{name := Name, mfa := MFA} = Job, TZ, Opts, IsNewJob) ->
    NewOpts = valid_opts(Opts),
    Pid = link_pid(MFA),
    JobRec = #job{status = activate, name = Name, job = Job, opts = NewOpts, link = Pid},
    Insert = ets:insert_new(JobTab, JobRec),
    Now = current_millisecond(),
    telemetry:execute(?Activate, #{action_ms => Now}, #{name => Name, mfa => MFA}),
    update_timer(Insert orelse IsNewJob, TZ, NewOpts, Job, Now, Pid, Tab, JobTab).

activate_job(JobTab, Name, TZ, Tab) ->
    case ets:lookup(JobTab, Name) of
        [] -> {error, not_found};
        [#job{job = Job, opts = Opts}] ->
            delete_job(JobTab, Tab, Name),
            case add_job(JobTab, Tab, Job, TZ, Opts, false) of
                {ok, Name} -> ok;
                Err -> Err
            end
    end.

deactivate_job(JobTab, Name, Timer) ->
    ets:select_delete(Timer, ?MatchSpec(Name)),
    case ets:update_element(JobTab, Name, {#job.status, deactivate}) of
        true ->
            telemetry:execute(?Deactivate, #{action_ms => current_millisecond()}, #{name => Name}),
            ok;
        false -> {error, not_found}
    end.

delete_job(JobTab, TimerTab, Name) ->
    ets:select_delete(TimerTab, ?MatchSpec(Name)),
    telemetry:execute(?Delete, #{action_ms => current_millisecond()}, #{name => Name}),
    case ets:lookup(JobTab, Name) of
        [] -> ok;
        [#job{link = Link}] ->
            unlink_pid(Link),
            ets:delete(JobTab, Name)
    end.

update_timer(false, _, _, _, _, _, _, _) -> {error, already_exist};
update_timer(true, TZ, Opts, Job, Now, LinkPid, Tab, JobTab) ->
    Singleton = proplists:get_value(singleton, Opts),
    MaxCount = proplists:get_value(max_count, Opts),
    #{name := Name, crontab := Spec, type := Type, mfa := MFA,
        start_time := StartTime, end_time := EndTime} = Job,
    Start = datetime_to_millisecond(TZ, StartTime),
    End = datetime_to_millisecond(TZ, EndTime),
    case next_schedule_millisecond(Type, Spec, TZ, Now, Start, End) of
        {ok, NextSec} ->
            Timer = #timer{key = {NextSec, Name}, singleton = Singleton,
                name = Name, type = Type, spec = Spec, max_count = MaxCount,
                mfa = MFA, start_sec = Start, end_sec = End, link = LinkPid},
            ets:insert(Tab, Timer),
            {ok, Name};
        {error, already_ended} = Err ->
            delete_job(JobTab, Tab, Name),
            Err
    end.

current_millisecond() -> erlang:system_time(millisecond).

datetime_to_millisecond(_, unlimited) -> unlimited;
datetime_to_millisecond(local, DateTime) ->
    UtcTime = erlang:localtime_to_universaltime(DateTime),
    datetime_to_millisecond(utc, UtcTime);
datetime_to_millisecond(utc, DateTime) ->
    (calendar:datetime_to_gregorian_seconds(DateTime) - ?SECONDS_FROM_0_TO_1970) * 1000.

millisecond_to_datetime(local, Ms) -> calendar:system_time_to_local_time(Ms, millisecond);
millisecond_to_datetime(utc, Ms) -> calendar:system_time_to_universal_time(Ms, millisecond).

spawn_mfa(JobTab, Name, MFA) ->
    Start = erlang:monotonic_time(),
    {Event, OkInc, FailedInc, NewRes} =
        try
            case MFA of
                {erlang, send, [Pid, Message]} ->
                    erlang:send(Pid, Message),
                    {?Success, 1, 0, ok};
                {M, F, A} -> {?Success, 1, 0, apply(M, F, A)};
                {F, A} -> {?Success, 1, 0, apply(F, A)}
            end
        catch
            Error:Reason:Stacktrace ->
                {?Failure, 0, 1, {Error, Reason, Stacktrace}}
        end,
    End = erlang:monotonic_time(),
    Cost = erlang:convert_time_unit(End - Start, native, microsecond),
    telemetry:execute(Event, #{run_microsecond => Cost, run_result => NewRes}, #{name => Name, mfa => MFA}),
    case ets:lookup(JobTab, Name) of
        [] -> ok;
        [Job] ->
            #job{ok = Ok, failed = Failed, run_microsecond = RunMs, result = Results} = Job,
            Elements = [{#job.ok, Ok + OkInc}, {#job.failed, Failed + FailedInc},
                {#job.run_microsecond, lists:sublist([Cost | RunMs], ?MAX_SIZE)},
                {#job.result, lists:sublist([NewRes | Results], ?MAX_SIZE)}],
            ets:update_element(JobTab, Name, Elements)
    end.

tick(State = #state{timer_tab = TimerTab}) ->
    tick_tick(ets:first(TimerTab), current_millisecond(), State).

tick_tick('$end_of_table', _Cur, _State) -> infinity;
tick_tick({Due, _Name}, Cur, #state{max_timeout = MaxTimeout}) when Due > Cur ->
    min(Due - Cur, MaxTimeout);
tick_tick(Key = {Due, Name}, Cur, State) ->
    #state{time_zone = TZ, timer_tab = TimerTab, job_tab = JobTab} = State,
    [Cron = #timer{singleton = Singleton, mfa = MFA, max_count = MaxCount, cur_count = CurCount}] = ets:lookup(TimerTab, Key),
    ets:delete(TimerTab, Key),
    {Incr, CurPid} = maybe_spawn_worker(Cur - Due < 1000, Singleton, Name, MFA, JobTab),
    update_next_schedule(CurCount + Incr, MaxCount, Cron, Cur, Name, TZ, CurPid, TimerTab, JobTab),
    tick(State).

update_next_schedule(Max, Max, _Cron, _Cur, Name, _TZ, _CurPid, Tab, JobTab) -> delete_job(JobTab, Tab, Name);
update_next_schedule(Count, _Max, Cron, Cur, Name, TZ, CurPid, Tab, JobTab) ->
    #timer{type = Type, start_sec = Start, end_sec = End, spec = Spec} = Cron,
    case next_schedule_millisecond(Type, Spec, TZ, Cur, Start, End) of
        {ok, Next} ->
            NextTimer = Cron#timer{key = {Next, Name}, singleton = CurPid, cur_count = Count},
            ets:insert(Tab, NextTimer);
        {error, already_ended} ->
            delete_job(JobTab, Tab, Name)
    end.

next_schedule_millisecond(every, Sec, _TimeZone, Now, Start, End) ->
    Next = Now + Sec * 1000,
    case in_range(Next, Start, End) of
        {error, deactivate} -> {ok, Start};
        {error, already_ended} -> {error, already_ended};
        ok -> {ok, Next}
    end;
next_schedule_millisecond(cron, Spec, TimeZone, Now, Start, End) ->
    ForwardDateTime = millisecond_to_datetime(TimeZone, Now + 1000),
    DefaultMin = #{second => 0, minute => 0, hour => 0,
        day_of_month => 1, month => 1, day_of_week => 0},
    Min = spec_min(maps:to_list(Spec), DefaultMin),
    NextDateTime = next_schedule_datetime(Spec, Min, ForwardDateTime),
    Next = datetime_to_millisecond(TimeZone, NextDateTime),
    case in_range(Next, Start, End) of
        {error, deactivate} -> next_schedule_millisecond(cron, Spec, TimeZone, Start, Start, End);
        {error, already_ended} -> {error, already_ended};
        ok -> {ok, Next}
    end.

next_schedule_datetime(DateSpec, Min, DateTime) ->
    #{
        second := SecondSpec, minute := MinuteSpec, hour := HourSpec,
        day_of_month := DayOfMonthSpec, month := MonthSpec,
        day_of_week := DayOfWeekSpec} = DateSpec,
    {{Year, Month, Day}, {Hour, Minute, Second}} = DateTime,
    case valid_datetime(MonthSpec, Month) of
        false -> forward_month(DateTime, Min, DateSpec);
        true ->
            case valid_day(Year, Month, Day, DayOfMonthSpec, DayOfWeekSpec) of
                false ->
                    LastDay = calendar:last_day_of_the_month(Year, Month),
                    forward_day(DateTime, Min, LastDay, DateSpec);
                true ->
                    case valid_datetime(HourSpec, Hour) of
                        false -> forward_hour(DateTime, Min, DateSpec);
                        true ->
                            case valid_datetime(MinuteSpec, Minute) of
                                false -> forward_minute(DateTime, Min, DateSpec);
                                true ->
                                    case valid_datetime(SecondSpec, Second) of
                                        false -> forward_second(DateTime, Min, DateSpec);
                                        true -> DateTime
                                    end
                            end
                    end
            end
    end.

forward_second(DateTime, Min, Spec) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = DateTime,
    NewSecond = nearest(second, Second, 59, Spec),
    case Second >= NewSecond of
        true -> forward_minute(DateTime, Min, Spec);
        false -> {{Year, Month, Day}, {Hour, Minute, NewSecond}}
    end.

forward_minute(DateTime, Min, Spec) ->
    {{Year, Month, Day}, {Hour, Minute, _Second}} = DateTime,
    NewMinute = nearest(minute, Minute, 59, Spec),
    case Minute >= NewMinute of
        true -> forward_hour(DateTime, Min, Spec);
        false ->
            #{second := SecondM} = Min,
            {{Year, Month, Day}, {Hour, NewMinute, SecondM}}
    end.

forward_hour(DateTime, Min, Spec) ->
    {{Year, Month, Day}, {Hour, _Minute, _Second}} = DateTime,
    NewHour = nearest(hour, Hour, 23, Spec),
    case Hour >= NewHour of
        true ->
            LastDay = calendar:last_day_of_the_month(Year, Month),
            forward_day(DateTime, Min, LastDay, Spec);
        false ->
            #{minute := MinuteM, second := SecondM} = Min,
            {{Year, Month, Day}, {NewHour, MinuteM, SecondM}}
    end.

forward_day(DateTime, Min, LastDay, Spec) ->
    {{Year, Month, Day}, {_Hour, _Minute, _Second}} = DateTime,
    case Day + 1 of
        NewDay when NewDay > LastDay -> forward_month(DateTime, Min, Spec);
        NewDay ->
            #{hour := HourM, minute := MinuteM, second := SecondM} = Min,
            NewDateTime = {{Year, Month, NewDay}, {HourM, MinuteM, SecondM}},
            #{day_of_week := DayOfWeekSpec, day_of_month := DayOfMonthSpec} = Spec,
            case valid_day(Year, Month, NewDay, DayOfMonthSpec, DayOfWeekSpec) of
                true -> NewDateTime;
                false -> forward_day(NewDateTime, Min, LastDay, Spec)
            end
    end.

forward_month(DateTime, Min, Spec) ->
    {{Year, Month, _Day}, {_Hour, _Minute, _Second}} = DateTime,
    NewMonth = nearest(month, Month, 12, Spec),
    #{month := MonthM, hour := HourM, minute := MinuteM, second := SecondM} = Min,
    NewDateTime =
        {{NYear, NMonth, NDay}, {_NHour, _NMinute, _NSecond}} =
        case Month >= NewMonth of
            true -> {{Year + 1, MonthM, 1}, {HourM, MinuteM, SecondM}};
            false -> {{Year, NewMonth, 1}, {HourM, MinuteM, SecondM}}
        end,
    #{day_of_week := DayOfWeekSpec, day_of_month := DayOfMonthSpec} = Spec,
    case valid_day(NYear, NMonth, NDay, DayOfMonthSpec, DayOfWeekSpec) of
        false ->
            LastDay = calendar:last_day_of_the_month(NYear, NMonth),
            forward_day(NewDateTime, Min, LastDay, Spec);
        true -> NewDateTime
    end.

nearest(Type, Current, Max, Spec) ->
    Values = maps:get(Type, Spec),
    nearest_1(Values, Values, Max, Current + 1).

nearest_1('*', '*', MaxLimit, Next) when Next > MaxLimit -> 1;
nearest_1('*', '*', _MaxLimit, Next) -> Next;
nearest_1([], [{Min, _} | _], _Max, _Next) -> Min;
nearest_1([], [Min | _], _Max, _Next) -> Min;
nearest_1([{Min, Max} | Rest], Spec, MaxLimit, Next) ->
    if
        Next > Max -> nearest_1(Rest, Spec, MaxLimit, Next);
        Next =< Min -> Min;
        true -> Next
    end;
nearest_1([Expect | Rest], Spec, MaxLimit, Next) ->
    case Next > Expect of
        true -> nearest_1(Rest, Spec, MaxLimit, Next);
        false -> Expect
    end.

valid_datetime('*', _Value) -> true;
valid_datetime([], _Value) -> false;
valid_datetime([Value | _T], Value) -> true;
valid_datetime([{Lower, Upper} | _], Value) when Lower =< Value andalso Value =< Upper -> true;
valid_datetime([_ | T], Value) -> valid_datetime(T, Value).

valid_day(_Year, _Month, _Day, '*', '*') -> true;
valid_day(_Year, _Month, Day, DayOfMonthSpec, '*') ->
    valid_datetime(DayOfMonthSpec, Day);
valid_day(Year, Month, Day, '*', DayOfWeekSpec) ->
    DayOfWeek = ?day_of_week(Year, Month, Day),
    valid_datetime(DayOfWeekSpec, DayOfWeek);
valid_day(Year, Month, Day, DayOfMonthSpec, DayOfWeekSpec) ->
    case valid_datetime(DayOfMonthSpec, Day) of
        false ->
            DayOfWeek = ?day_of_week(Year, Month, Day),
            valid_datetime(DayOfWeekSpec, DayOfWeek);
        true -> true
    end.

spec_min([], Acc) -> Acc;
spec_min([{Key, Value} | Rest], Acc) ->
    NewAcc =
        case Value of
            '*' -> Acc;
            [{Min, _} | _] -> Acc#{Key => Min};
            [Min | _] -> Acc#{Key => Min}
        end,
    spec_min(Rest, NewAcc).

next_timeout(#state{max_timeout = MaxTimeout, timer_tab = TimerTab}) ->
    case ets:first(TimerTab) of
        '$end_of_table' -> infinity;
        {Due, _} -> min(max(Due - current_millisecond(), 0), MaxTimeout)
    end.

in_range(_Current, unlimited, unlimited) -> ok;
in_range(Current, unlimited, End) when Current > End -> {error, already_ended};
in_range(_Current, unlimited, _End) -> ok;
in_range(Current, Start, unlimited) when Current < Start -> {error, deactivate};
in_range(_Current, _Start, unlimited) -> ok;
in_range(Current, _Start, End) when Current > End -> {error, already_ended};
in_range(Current, Start, _End) when Current < Start -> {error, deactivate};
in_range(_Current, _Start, _End) -> ok.

to_rfc3339(unlimited) -> unlimited;
to_rfc3339(Next) -> calendar:system_time_to_rfc3339(Next div 1000, [{unit, second}]).

predict_datetime(deactivate, _, _, _, _, _, _) -> [];
predict_datetime(activate, #{type := every, crontab := Sec} = Job, Start, End, Num, TimeZone, NowT) ->
    Now = case maps:find(name, Job) of error -> NowT; _ -> NowT - Sec * 1000 end,
    predict_datetime_2(Job, TimeZone, Now, Start, End, Num, []);
predict_datetime(activate, Job, Start, End, Num, TimeZone, Now) ->
    predict_datetime_2(Job, TimeZone, Now, Start, End, Num, []).

predict_datetime_2(_Job, _TimeZone, _Now, _Start, _End, 0, Acc) -> lists:reverse(Acc);
predict_datetime_2(Job, TimeZone, Now, Start, End, Num, Acc) ->
    #{type := Type, crontab := Spec} = Job,
    case next_schedule_millisecond(Type, Spec, TimeZone, Now, Start, End) of
        {ok, Next} ->
            NewAcc = [to_rfc3339(Next) | Acc],
            predict_datetime_2(Job, TimeZone, Next, Start, End, Num - 1, NewAcc);
        {error, already_ended} -> lists:reverse(Acc)
    end.

get_next_schedule_time(Timer, Name) ->
    %% P = ets:fun2ms(fun(#timer{name = N, key = {Time, _}}) when N =:= Name -> Time end),
    P = [{#timer{key = {'$1', '_'}, name = '$2', _ = '_'}, [{'=:=', '$2', {const, Name}}], ['$1']}],
    case ets:select(Timer, P) of
        [T] -> T;
        [] -> current_millisecond()
    end.

get_time_zone() -> application:get_env(?Ecron, time_zone, local).
local_jobs() -> application:get_env(?Ecron, local_jobs, []).
global_jobs() -> application:get_env(?Ecron, global_jobs, []).

maybe_spawn_worker(true, _, Name, {erlang, send, Args}, JobTab) ->
    {1, spawn_mfa(JobTab, Name, {erlang, send, Args})};
maybe_spawn_worker(true, true, Name, MFA, JobTab) ->
    {1, spawn(?MODULE, spawn_mfa, [JobTab, Name, MFA])};
maybe_spawn_worker(true, false, Name, MFA, JobTab) ->
    spawn(?MODULE, spawn_mfa, [JobTab, Name, MFA]),
    {1, false};
maybe_spawn_worker(true, Pid, Name, MFA, JobTab) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> {0, Pid};
        false -> {1, spawn(?MODULE, spawn_mfa, [JobTab, Name, MFA])}
    end;
maybe_spawn_worker(false, Singleton, _Name, _MFA, _JobTab) -> {0, Singleton}.

pid_delete(Pid, TimerTab) ->
    TimerMatch = [{#timer{link = '$1', _ = '_'}, [], [{'=:=', '$1', {const, Pid}}]}],
    JobMatch = [{#job{link = '$1', _ = '_'}, [], [{'=:=', '$1', {const, Pid}}]}],
    ets:select_delete(TimerTab, TimerMatch),
    ets:select_delete(?Job, JobMatch).

valid_opts(Opts) ->
    Singleton = proplists:get_value(singleton, Opts, true),
    MaxCount = proplists:get_value(max_count, Opts, unlimited),
    [{singleton, Singleton}, {max_count, MaxCount}].
link_pid({erlang, send, [PidOrName, _Message]}) ->
    Pid = get_pid(PidOrName),
    is_pid(Pid) andalso (catch link(Pid)),
    Pid;
link_pid(_MFA) -> undefined.

unlink_pid(Pid) when is_pid(Pid) -> catch unlink(Pid);
unlink_pid(_) -> ok.

get_pid(Pid) when is_pid(Pid) -> Pid;
get_pid(Name) when is_atom(Name) -> whereis(Name).

job_to_statistic(Job = #job{name = Name}) ->
    TZ = get_time_zone(),
    Next = get_next_schedule_time(Name),
    job_to_statistic(Job, TZ, Next).

job_to_statistic(Name, State) ->
    #state{timer_tab = Timer, job_tab = JobTab, time_zone = TZ} = State,
    case ets:lookup(JobTab, Name) of
        [Job] ->
            Next = get_next_schedule_time(Timer, Name),
            {ok, job_to_statistic(Job, TZ, Next)};
        [] -> {error, not_found}
    end.

job_to_statistic(Job, TimeZone, Now) ->
    #job{job = JobSpec, status = Status, opts = Opts,
        ok = Ok, failed = Failed, result = Res, run_microsecond = RunMs} = Job,
    #{start_time := StartTime, end_time := EndTime} = JobSpec,
    Start = datetime_to_millisecond(TimeZone, StartTime),
    End = datetime_to_millisecond(TimeZone, EndTime),
    JobSpec#{status => Status, ok => Ok, failed => Failed, opts => Opts,
        next => predict_datetime(Status, JobSpec, Start, End, ?MAX_SIZE, TimeZone, Now),
        start_time => to_rfc3339(datetime_to_millisecond(TimeZone, StartTime)),
        end_time => to_rfc3339(datetime_to_millisecond(TimeZone, EndTime)),
        node => node(), results => Res, run_microsecond => RunMs}.

%% For PropEr Test
-ifdef(TEST).
-compile(export_all).
-endif.
