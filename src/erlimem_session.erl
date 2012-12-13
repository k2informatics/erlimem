-module(erlimem_session).
-behaviour(gen_server).

-include("erlimem.hrl").
-include_lib("imem/include/imem_meta.hrl").

-record(state, {
    status=closed,
    port,
    pool,
    session_id,
    stmts = [],
    connection = {type, handle},
    conn_param,
    idle_timer,
    schema,
    seco = undefined,
    event_pids=[]
}).

-record(drvstmt, {
        buf,
        ref,
        result,
        maxrows,
        viewfun
    }).

%% session APIs
-export([open/3
        , close/1
        , exec/2
        , exec/3
        , exec/4
        , read_block/2
        , run_cmd/3
		]).

% statement APIs
-export([start_async_read/1
        , get_buffer_max/1
        , rows_from/2
        , prev_rows/1
        , next_rows/1
        , update_rows/2
        , update_row/4
        , delete_row/2
        , insert_row/3
        , delete_rows/2
        , insert_rows/2
        , commit_modified/1
		]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

%% @doc open new session
open(Type, Opts, Cred) ->
    {ok, Pid} = gen_server:start(?MODULE, [Type, Opts, Cred], []),
    {?MODULE, Pid}.

close({?MODULE, Pid})          -> gen_server:call(Pid, stop);
close({?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {close_statement, StmtRef}).

exec(StmtStr,                                    Ctx) -> exec(StmtStr, 0, Ctx).
exec(StmtStr, BufferSize,                        Ctx) -> run_cmd(exec, [StmtStr, BufferSize], Ctx).
exec(StmtStr, BufferSize, Fun,                   Ctx) -> run_cmd(exec, [StmtStr, BufferSize, Fun], Ctx).
read_block(StmtRef,                              Ctx) -> run_cmd(read_block, [StmtRef], Ctx).
run_cmd(Cmd, Args, {?MODULE, Pid}) when is_list(Args) -> call(Pid, [Cmd|Args]).
get_buffer_max(              {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {get_buffer_max, StmtRef}).
rows_from(RowId,             {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {rows_from, StmtRef, RowId}).
prev_rows(                   {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {prev_rows, StmtRef}).
next_rows(                   {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {next_rows, StmtRef}).
update_row(RId, CId, Val,    {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {update_row, RId, CId, Val, StmtRef}).
delete_row(RId,              {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {delete_row, RId, StmtRef}).
insert_row(CId, Val,         {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {insert_row, CId, Val, StmtRef}).
update_rows(Rows,            {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {modify_rows, upd, Rows, StmtRef}).
delete_rows(Rows,            {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {modify_rows, del, Rows, StmtRef}).
insert_rows(Rows,            {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {modify_rows, ins, Rows, StmtRef}).
commit_modified(             {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {commit_modified, StmtRef}).
start_async_read(            {?MODULE, StmtRef, Pid}) ->
    ok = gen_server:call(Pid, {clear_buf, StmtRef}),
    gen_server:cast(Pid, {read_block_async, StmtRef}).

call(Pid, Msg) ->
    gen_server:call(Pid, Msg, ?IMEM_TIMEOUT).

init([Type, Opts, {User, Password}]) when is_binary(User), is_binary(Password) ->
    case connect(Type, Opts) of
        {ok, Connect, Schema} ->
            io:format(user, "~p started ~p connected to ~p~n", [?MODULE, self(), {Type, Opts}]),
            Timer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
            SeCo =  case Connect of
                {local, _} -> undefined;
                _ ->
io:format(user, "loggin in with ~p~n", [{User, {pwdmd5, Password}}]),
                    S = erlimem_cmds:exec({authenticate, undefined, adminSessionId, User, {pwdmd5, Password}}, Connect),
                    erlimem_cmds:exec({login,S}, Connect)
            end,
            {ok, #state{connection=Connect, schema=Schema, conn_param={Type, Opts}, idle_timer=Timer, seco=SeCo}};
        {error, Reason} -> {stop, Reason}
    end.

connect(tcp, {IpAddr, Port, Schema}) ->
    io:format(user, "connecting ~p~n", [{IpAddr, Port, Schema}]),
    {ok, Ip} = inet:getaddr(IpAddr, inet),
    {ok, Socket} = gen_tcp:connect(Ip, Port, []),
    inet:setopts(Socket, [{active, false}, binary, {packet, 0}, {nodelay, true}]),
    {ok, {tcp, Socket}, Schema};
connect(rpc, {Node, Schema}) when Node == node() -> connect(local_sec, {Schema});
connect(rpc, {Node, Schema}) when is_atom(Node)  -> {ok, {rpc, Node}, Schema};
connect(local_sec, {Schema})                     -> {ok, {local_sec, undefined}, Schema};
connect(local, {Schema})                         -> {ok, {local, undefined}, Schema}.

handle_call(stop, _From, #state{stmts=Stmts}=State) ->
    _ = [erlimem_buf:delete(Buf) || #drvstmt{buf=Buf} <- Stmts],
    {stop,normal,State};
handle_call({close_statement, StmtRef}, _From, #state{connection=Connection,seco=SeCo,stmts=Stmts}=State) ->
    case lists:keytake(StmtRef, 1, Stmts) of
        {value, {StmtRef, #drvstmt{buf=Buf}}, NewStmts} ->
            erlimem_buf:delete(Buf),
            erlimem_cmds:exec({close, SeCo, StmtRef}, Connection);
        false -> NewStmts = Stmts
    end,
    {reply,ok,State#state{stmts=NewStmts}};

handle_call({update_row, RowId, ColumId, Val, Ref}, From, #state{stmts=Stmts} = State) ->
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #drvstmt{buf=Buf} = Stmt,
    {{[Row],_,_}, _} = erlimem_buf:get_rows_from(Buf, RowId, 1),
    NewRow = lists:sublist(Row,ColumId) ++ [Val] ++ lists:nthtail(ColumId+1,Row),
    handle_call({modify_rows, upd, [NewRow], Ref}, From, State);
handle_call({delete_row, RowId, Ref}, From, #state{stmts=Stmts} = State) ->
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #drvstmt{buf=Buf} = Stmt,
    {{[Row],_,_}, _} = erlimem_buf:get_rows_from(Buf, RowId, 1),
    handle_call({modify_rows, del, [Row], Ref}, From, State);
handle_call({insert_row, Clm, Val, Ref}, From, #state{stmts=Stmts} = State) ->
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #drvstmt{buf=Buf, result={columns, Clms}} = Stmt,
    ColNameList = [atom_to_list(C#ddColMap.name)||C<-Clms],
    ColumId = string:str(ColNameList,[Clm]),
    Row = [C#ddColMap.default||C<-Clms],
    NewRow = lists:sublist(Row,ColumId-1) ++ [Val] ++ lists:nthtail(ColumId,Row),
    {reply,ok,NewState} = handle_call({modify_rows, ins, [NewRow], Ref}, From, State),
    {_,_,Count} = erlimem_buf:get_buffer_max(Buf),
    {reply,Count,NewState};

handle_call({clear_buf, Ref}, _From, #state{idle_timer=Timer,stmts=Stmts} = State) ->
    erlang:cancel_timer(Timer),
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #drvstmt{buf=Buf} = Stmt,
    NewBuf = erlimem_buf:clear(Buf),
    NewStmts = lists:keyreplace(Ref, 1, Stmts, {Ref, Stmt#drvstmt{buf=NewBuf}}),
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,ok,State#state{idle_timer=NewTimer,stmts=NewStmts}};
handle_call({get_buffer_max, Ref}, _From, #state{idle_timer=Timer,stmts=Stmts} = State) ->
    erlang:cancel_timer(Timer),
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #drvstmt{buf=Buf} = Stmt,
    Count = erlimem_buf:get_buffer_max(Buf),
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,Count,State#state{idle_timer=NewTimer}};
handle_call({rows_from, Ref, RowId}, _From, #state{idle_timer=Timer,stmts=Stmts} = State) ->
    erlang:cancel_timer(Timer),
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #drvstmt{buf=Buf, maxrows=MaxRows} = Stmt,
    {Rows, NewBuf} = erlimem_buf:get_rows_from(Buf, RowId, MaxRows),
    NewStmts = lists:keystore(Ref, 1, Stmts, {Ref, Stmt#drvstmt{buf=NewBuf}}),
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,Rows,State#state{idle_timer=NewTimer,stmts=NewStmts}};
handle_call({prev_rows, Ref}, _From, #state{idle_timer=Timer,stmts=Stmts} = State) ->
    erlang:cancel_timer(Timer),
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #drvstmt{buf=Buf, maxrows=MaxRows} = Stmt,
    {Rows, NewBuf} = erlimem_buf:get_prev_rows(Buf, MaxRows),
    NewStmts = lists:keystore(Ref, 1, Stmts, {Ref, Stmt#drvstmt{buf=NewBuf}}),
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,Rows,State#state{idle_timer=NewTimer,stmts=NewStmts}};
handle_call({next_rows, Ref}, _From, #state{idle_timer=Timer,stmts=Stmts} = State) ->
    erlang:cancel_timer(Timer),
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #drvstmt{buf=Buf, maxrows=MaxRows} = Stmt,
    {Rows, NewBuf} = erlimem_buf:get_next_rows(Buf, MaxRows),
    NewStmts = lists:keystore(Ref, 1, Stmts, {Ref, Stmt#drvstmt{buf=NewBuf}}),
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,Rows,State#state{idle_timer=NewTimer,stmts=NewStmts}};
handle_call({modify_rows, Op, Rows, Ref}, _From, #state{idle_timer=Timer,stmts=Stmts} = State) ->
    erlang:cancel_timer(Timer),
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #drvstmt{buf=Buf} = Stmt,
    erlimem_buf:modify_rows(Buf, Op, Rows),
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,ok,State#state{idle_timer=NewTimer}};
handle_call({commit_modified, StmtRef}, _From, #state{connection=Connection,seco=SeCo,idle_timer=Timer,stmts=Stmts} = State) ->
    erlang:cancel_timer(Timer),
    {_, Stmt} = lists:keyfind(StmtRef, 1, Stmts),
    #drvstmt{buf=Buf} = Stmt,
    Rows = erlimem_buf:get_modified_rows(Buf),
    io:format(user, "Modified rows ~p~n", [Rows]),
    Result =
    try
        erlimem_cmds:exec({update_cursor_prepare, SeCo, StmtRef, Rows}, Connection),
        erlimem_cmds:exec({update_cursor_execute, SeCo, StmtRef, optimistic}, Connection),
        erlimem_cmds:exec({fetch_close, SeCo, StmtRef}, Connection),
        Rows
    catch
        _Class:{Res,ST} ->
            io:format(user, "[ERROR] ~p~n", [{Res, ST}]),
            {error, Res}
    end,
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,Result,State#state{idle_timer=NewTimer}};

handle_call(Msg, {From, _}, #state{connection=Connection,idle_timer=Timer,stmts=Stmts, schema=Schema, seco=SeCo, event_pids=EvtPids} = State) ->
    erlang:cancel_timer(Timer),
    [Cmd|Rest] = Msg,
    NewMsg = case Cmd of
        exec ->
            NewEvtPids = EvtPids,
            [_,MaxRows|_] = Rest,
            list_to_tuple([Cmd,SeCo|Rest] ++ [Schema]);
        subscribe ->
            MaxRows = 0,
            [Evt|_] = Rest,
            NewEvtPids = lists:keystore(Evt, 1, EvtPids, {Evt, From}),
            list_to_tuple([Cmd,SeCo|Rest]);
        _ ->
            NewEvtPids = EvtPids,
            MaxRows = 0,
            list_to_tuple([Cmd,SeCo|Rest])
    end,
    {NewState, Result} = try
        case erlimem_cmds:exec(NewMsg, Connection) of
            {ok, Clms, Fun, Ref} ->
                Rslt = {ok, Clms, {?MODULE, Ref, self()}},
                {State#state{stmts=lists:keystore(Ref, 1, Stmts,
                                {Ref, #drvstmt{ result   = {columns, Clms}
                                                , ref      = Ref
                                                , buf      = erlimem_buf:create(Fun)
                                                , maxrows  = MaxRows}
                                })
                           },
                Rslt};
            Res ->
                {State, Res}
        end
    catch
        _Class:ExcpRes -> {State, {error, ExcpRes}}
    end,
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,Result,NewState#state{idle_timer=NewTimer, event_pids=NewEvtPids}}.

handle_cast({read_block_async, StmtRef}, #state{connection=Connection, seco=SeCo}=State) ->    
    erlimem_cmds:exec({fetch_recs_async, SeCo, StmtRef}, Connection),
    {noreply, State};
handle_cast({async_resp, {StmtRef, Resp}}, #state{stmts=Stmts, seco=SeCo}=State) ->
    {_, #drvstmt{buf=Buffer}} = lists:keyfind(StmtRef, 1, Stmts),
    case Resp of
        {[], _} -> io:format(user, "async_resp~n", []);
        {error, Result} -> io:format(user, "erlimem - async resp error ~p~n", [Result]);
        {Rows, _Complete} ->
            erlimem_buf:insert_rows(Buffer, Rows), % [Fun(R) || R <- Rows]
            gen_server:cast(self(), {read_block_async, SeCo, StmtRef});
        Unknown -> io:format(user, "Unknown resp for row fetch~p~n", [Unknown])
    end,
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({_,{complete, _}} = Evt, #state{event_pids=EvtPids}=State) ->
    case lists:keyfind(activity, 1, EvtPids) of
        {_, Pid} when is_pid(Pid) -> Pid ! Evt;
        Found -> io:format(user, "# ~p <- ~p~n", [Found, Evt])
    end,
    {noreply, State};
handle_info({_,{S, Ctx, _}} = Evt, #state{event_pids=EvtPids}=State) when S =:= write;
                                                                          S =:= delete_object;
                                                                          S =:= delete ->
    Tab = case Ctx of
        {T,_} -> T;
        Ctx -> element(1, Ctx)
    end,
    case lists:keyfind({table, Tab}, 1, EvtPids) of
        {_, Pid} -> Pid ! Evt;
        _ ->
            case lists:keyfind({table, Tab, simple}, 1, EvtPids) of
                {_, Pid} when is_pid(Pid) -> Pid ! Evt;
                Found -> io:format(user, "# ~p <- ~p~n", [Found, Evt])
            end
    end,
    {noreply, State};
handle_info({_,{D,Tab,_,_,_}} = Evt, #state{event_pids=EvtPids}=State) when D =:= write;
                                                                            D =:= delete ->
    case lists:keyfind({table, Tab, detailed}, 1, EvtPids) of
        {_, Pid} when is_pid(Pid) -> Pid ! Evt;
        Found -> io:format(user, "# ~p <- ~p~n", [Found, Evt])
    end,
    {noreply, State};
handle_info(timeout, State) ->
    close({?MODULE, self()}),
    {noreply, State};
handle_info(Info, State) ->
    io:format(user, "*************** Info ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, #state{conn_param={Type, Opts},idle_timer=Timer}) ->
    erlang:cancel_timer(Timer),
    io:format(user, "stopped ~p ~p disconnected from ~p~n", [?MODULE, self(), {Type, Opts}]).

code_change(_OldVsn, State, _Extra) -> {ok, State}.


% EUnit tests --

-include_lib("eunit/include/eunit.hrl").

setup(Type) -> 
    dbg:start(),
    dbg:tracer(),
    dbg:tpl(erlimem_cmd, []),
    dbg:p(all, c),
    User = <<"admin">>,
    Password = erlang:md5(<<"change_on_install">>),
    Cred = {User, Password},
    erlimem:start(),
    ImemRunning = lists:keymember(imem, 1, application:which_applications()),
    Schema =
    if ((Type =:= local) orelse (Type =:= local_sec)) andalso (ImemRunning == false) ->
            application:load(imem),
            {ok, S} = application:get_env(imem, mnesia_schema_name),
            {ok, Cwd} = file:get_cwd(),
            NewSchema = Cwd ++ "/../" ++ atom_to_list(S),
            application:set_env(mnesia, dir, NewSchema),
            application:set_env(imem, mnesia_node_type, ram),
            application:start(imem),
            S;
        true -> 'Imem'
    end,
    io:format(user, "schema ~p~n", [Schema]),
    case Type of
        tcp         -> erlimem_session:open(tcp, {localhost, 8124, Schema}, Cred);
        local_sec   -> erlimem_session:open(local_sec, {Schema}, Cred);
        local       -> erlimem_session:open(local, {Schema}, Cred)
    end.

setup() ->
    random:seed(erlang:now()),
    setup(local).

teardown(_Sess) ->
   % Sess:close(),
    erlimem:stop(),
    application:stop(imem).

db_test_() ->
    {timeout, 1000000, {
        setup,
        fun setup/0,
        fun teardown/1,
        {with, [
                fun all_tables/1
                , fun table_create_select_drop/1
                , fun table_modify/1
        ]}
        }
    }.

all_tables(Sess) ->
    io:format(user, "--------- select from all_tables (all_tables) ---------------~n", []),
    {ok, Clms, Statement} = Sess:exec("select qname from all_tables;", 100),
    io:format(user, "select ~p~n", [{Clms, Statement}]),
    Statement:start_async_read(),
    io:format(user, "receiving...~n", []),
    timer:sleep(1000),
    {Rows,_,_} = Statement:next_rows(),
    io:format(user, "received ~p~n", [Rows]),
    Statement:close(),
    io:format(user, "statement closed~n", []),
    io:format(user, "------------------------------------------------------------~n", []).

table_create_select_drop(Sess) ->
    io:format(user, "-- create insert select drop (table_create_select_drop) ----~n", []),
    Table = def,
    Res = Sess:exec("create table "++atom_to_list(Table)++" (col1 int, col2 char);"),
    io:format(user, "Create ~p~n", [Res]),
    Res1 = Sess:run_cmd(subscribe, [{table,Table,simple}]),
    io:format(user, "subscribe ~p~n", [Res1]),
    % - {error, Result} = Sess:exec("create table Table (col1 int, col2 char);"),
    % - io:format(user, "Duplicate Create ~p~n", [Result]),
    Res0 = insert_range(Sess, 20, atom_to_list(Table)),
    io:format(user, "insert ~p~n", [Res0]),
    {ok, Clms, Statement} = Sess:exec("select * from "++atom_to_list(Table)++";", 100),
    io:format(user, "select ~p~n", [{Clms, Statement}]),
    Statement:start_async_read(),
    timer:sleep(1000),
    io:format(user, "receiving...~n", []),
    {Rows,_,_} = Statement:next_rows(),
    Statement:close(),
    io:format(user, "statement closed~n", []),
    io:format(user, "received ~p~n", [length(Rows)]),
    ok = Sess:exec("drop table "++atom_to_list(Table)++";"),
    io:format(user, "drop table~n", []),
    io:format(user, "------------------------------------------------------------~n", []).

table_modify(Sess) ->
    io:format(user, "------- update insert new delete rows (table_modify) -------~n", []),
    Table = def,
    Sess:exec("create table "++atom_to_list(Table)++" (col1 int, col2 char);"),
    NumRows = 10,
    insert_range(Sess, NumRows, atom_to_list(Table)),
    {ok, _, Statement} = Sess:exec("select * from "++atom_to_list(Table)++";", 100),
    Statement:start_async_read(),
    timer:sleep(1000),
    {Rows,_,_} = Statement:next_rows(),
    io:format(user, "original table from db ~p~n", [Rows]),
    Statement:update_rows(update_random(length(Rows)-1,5,Rows)), % modify some rows in buffer
    Statement:delete_rows(update_random(length(Rows)-1,5,Rows)), % delete some rows in buffer
    Statement:insert_rows(insert_random(length(Rows)-1,5,[])),   % insert some rows in buffer
    Rows9 = Statement:commit_modified(),
    io:format(user, "changed rows ~p~n", [Rows9]),
    Statement:start_async_read(),
    timer:sleep(1000),
    {NewRows1,_,_} = Statement:next_rows(),
    io:format(user, "modified table from db ~p~n", [NewRows1]),
    Statement:close(),
    ok = Sess:exec("drop table "++atom_to_list(Table)++";"),
    io:format(user, "------------------------------------------------------------~n", []).

insert_random(_, 0, Rows) -> Rows;
insert_random(Max, Count, Rows) ->
    Idx = Max + random:uniform(Max),
    insert_random(Max, Count-1, [[Idx, Idx]|Rows]).

update_random(Max, Count, Rows) -> update_random(Max-1, Count, Rows, []).
update_random(_, 0, _, NewRows) -> NewRows;
update_random(Max, Count, Rows, NewRows) ->
    Idx = random:uniform(Max),
    {_, B} = lists:split(Idx-1, Rows),
    [I,PK,_|Rest] = lists:nth(1,B),
    update_random(Max, Count-1, Rows, NewRows ++ [[I,PK,Idx|Rest]]).

insert_range(_Sess, 0, _TableName) -> ok;
insert_range(Sess, N, TableName) when is_integer(N), N > 0 ->
    Sess:exec("insert into " ++ TableName ++ " values (" ++ integer_to_list(N) ++ ", '" ++ integer_to_list(N) ++ "');"),
    insert_range(Sess, N-1, TableName).
