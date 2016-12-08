%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 9:27 PM
%%%-------------------------------------------------------------------
-module(navstar_overlay_configure).
-author("sdhillon").
-author("dgoel").

%% API
-export([start_link/1, stop/1, maybe_configure/2]).

-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").

-type config() :: #{key := term(), value := term()}.

-spec(start_link(config()) -> pid()).
start_link(Config) ->
   MyPid = self(),
   spawn_link(?MODULE, maybe_configure, [Config, MyPid]).

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill).

reply(Pid, Msg) ->
    Pid ! Msg.

-spec(maybe_configure(config(), pid()) -> term()).
maybe_configure(Config, MyPid) ->
    lager:debug("Started applying config ~p~n", [Config]),
    KnownOverlays = navstar_overlay_poller:overlays(),
    lists:map(
        fun(Overlay) -> try_configure_overlay(Config, Overlay) end,
        KnownOverlays
    ),
    lager:debug("Done applying config ~p for overlays ~p~n", [Config, KnownOverlays]),
    reply(MyPid, {navstar_overlay_configure, applied_config, Config}).

-spec(try_configure_overlay(config(), #mesos_state_agentoverlayinfo{}) -> term()).
try_configure_overlay(Config, Overlay) ->
    #mesos_state_agentoverlayinfo{info = #mesos_state_overlayinfo{subnet = Subnet}} = Overlay,
    ParsedSubnet = parse_subnet(Subnet),
    try_configure_overlay2(Config, Overlay, ParsedSubnet).

-type prefix_len() :: 0..32.
-spec(parse_subnet(Subnet :: binary()) -> {inet:ipv4_address(), prefix_len()}).
parse_subnet(Subnet) ->
    [IPBin, PrefixLenBin] = binary:split(Subnet, <<"/">>),
    {ok, IP} = inet:parse_ipv4_address(binary_to_list(IPBin)),
    PrefixLen = erlang:binary_to_integer(PrefixLenBin),
    true = is_integer(PrefixLen),
    true = 0 =< PrefixLen andalso PrefixLen =< 32,
    {IP, PrefixLen}.

try_configure_overlay2(_Config = #{key := [navstar, overlay, Subnet], value := LashupValue},
    Overlay, ParsedSubnet) when Subnet == ParsedSubnet ->
    lists:map(
        fun(Value) -> maybe_configure_overlay_entry(Overlay, Value) end,
        LashupValue
    );
try_configure_overlay2(_Config, _Overlay, _ParsedSubnet) ->
    ok.

maybe_configure_overlay_entry(Overlay, {{VTEPIPPrefix, riak_dt_map}, Value}) ->
    MyIP = navstar_overlay_poller:ip(),
    case lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, Value) of
        {_, MyIP} ->
            ok;
        _Any ->
            configure_overlay_entry(Overlay, VTEPIPPrefix, Value)
    end.

configure_overlay_entry(Overlay, _VTEPIPPrefix = {VTEPIP, _PrefixLen}, LashupValue) ->
    #mesos_state_agentoverlayinfo{
        backend = #mesos_state_backendinfo{
            vxlan = #mesos_state_vxlaninfo{
                vtep_name = VTEPName
            }
        }
    } = Overlay,
    {_, MAC} = lists:keyfind({mac, riak_dt_lwwreg}, 1, LashupValue),
    {_, AgentIP} = lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, LashupValue),
    {_, {SubnetIP, SubnetPrefixLen}} = lists:keyfind({subnet, riak_dt_lwwreg}, 1, LashupValue),
    FormattedMAC = vtep_mac(MAC),
    FormattedAgentIP = inet:ntoa(AgentIP),
    FormattedVTEPIP = inet:ntoa(VTEPIP),
    FormattedSubnetIP = inet:ntoa(SubnetIP),

    %% TEST only : writes the parameters to a file
    maybe_print_parameters([FormattedAgentIP, binary_to_list(VTEPName),
                            FormattedVTEPIP, FormattedMAC, 
                            FormattedSubnetIP, SubnetPrefixLen]),

    Pid = navstar_overlay_poller:netlink(),
    VTEPNameStr = binary_to_list(VTEPName),
    MACTuple = list_to_tuple(MAC),
    {ok, _} = navstar_overlay_netlink:ipneigh_replace(Pid, VTEPIP, MACTuple, VTEPNameStr),
    {ok, _} = navstar_overlay_netlink:bridge_fdb_replace(Pid, AgentIP, MACTuple, VTEPNameStr),
    {ok, _} = navstar_overlay_netlink:iproute_replace(Pid, AgentIP, 32, VTEPIP, 42),
    {ok, _} = navstar_overlay_netlink:iproute_replace(Pid, SubnetIP, SubnetPrefixLen, VTEPIP, main).

vtep_mac(IntList) ->
    HexList = lists:map(fun(X) -> erlang:integer_to_list(X, 16) end, IntList),
    lists:flatten(string:join(HexList, ":")).

-ifdef(TEST).
maybe_print_parameters(Parameters) ->
    {ok, PrivDir} = application:get_env(navstar_overlay, outputdir),
    File = filename:join(PrivDir, node()),
    ok = file:write_file(File, io_lib:fwrite("~p.\n",[Parameters]), [append]).

-else.
maybe_print_parameters(_) ->
    ok.
-endif.
