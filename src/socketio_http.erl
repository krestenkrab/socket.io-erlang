-module(socketio_http).
-include_lib("socketio.hrl").
-behaviour(gen_server).

%% API
-export([start_link/3, start/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, {
          default_http_handler,
          message_handler,
          sessions
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Port, DefaultHttpHandler, MessageHandler) ->
    gen_server:start_link(?MODULE, [Port, DefaultHttpHandler, MessageHandler], []).

start(Port, DefaultHttpHandler, MessageHandler) ->
    supervisor:start_child(socketio_http_sup, [Port, DefaultHttpHandler, MessageHandler]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Port, DefaultHttpHandler, MessageHandler]) ->
    Self = self(),
    process_flag(trap_exit, true),
    misultin:start_link([{port, Port},
                         {loop, fun (Req) -> handle_http(Self, Req) end},
                         {ws_loop, fun (Ws) -> handle_websocket(Self, Ws) end},
                         {ws_autoexit, false}
                        ]),
    {ok, #state{
       default_http_handler = DefaultHttpHandler,
       message_handler = MessageHandler,
       sessions = ets:new(socketio_sessions,[public])
      }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({request, {abs_path, "/socket.io.js"}, Req}, _From, State) ->
    Response = Req:file(filename:join([filename:dirname(code:which(?MODULE)), "..", "priv", "Socket.IO", "socket.io.js"])),
    {reply, Response, State};

%% If we can't route it, let others deal with it
handle_call({request, _, _} = Req, From, #state{ default_http_handler = HttpHandler } = State) when is_atom(HttpHandler) ->
    handle_call(Req, From, State#state{ default_http_handler = fun(P1, P2) -> HttpHandler:handle_request(P1, P2) end });

handle_call({request, Path, Req}, _From, #state{ default_http_handler = HttpHandler } = State) when is_function(HttpHandler) ->
    Response = HttpHandler(Path, Req),
    {reply, Response, State};

%% Sessions
handle_call({session, generate, ConnectionReference}, _From, #state{ message_handler = MessageHandler, sessions = Sessions } = State) ->
    UUID = binary_to_list(ossp_uuid:make(v4, text)),
    {ok, Pid} = socketio_client:start(UUID, MessageHandler, ConnectionReference),
    link(Pid),
    ets:insert(Sessions, [{UUID, Pid}, {Pid, UUID}]),
    {reply, {UUID, Pid}, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, _}, #state{ sessions = Sessions } = State) ->
    case ets:lookup(Sessions, Pid) of
        [{Pid, UUID}] ->
            ets:delete(Sessions,UUID),
            ets:delete(Sessions,Pid);
        _ ->
            ignore
    end,
    {noreply, State};
            
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    io:format("~p~n",[_Reason]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
handle_http(Server, Req) ->
    gen_server:call(Server, {request, Req:get(uri), Req}).

handle_websocket(Server, Ws) ->
    {SessionID, Pid} = gen_server:call(Server, {session, generate, {websocket, Ws}}),
    ok = gen_server:cast(Pid, {send, #msg{ content = SessionID }}),
    handle_websocket(Server, Ws, SessionID, Pid).

handle_websocket(Server, Ws, SessionID, Pid) ->
    receive
        {browser, Data} ->
            gen_server:call(Pid, {websocket, Data, Ws}),
            handle_websocket(Server, Ws, SessionID, Pid);
        closed ->
            gen_server:call(Pid, stop);
        _Ignore ->
            handle_websocket(Server, Ws, SessionID, Pid)
    end.

