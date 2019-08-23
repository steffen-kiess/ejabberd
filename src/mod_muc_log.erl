%%%----------------------------------------------------------------------
%%% File    : mod_muc_log.erl
%%% Author  : Badlop@process-one.net
%%% Purpose : MUC room logging
%%% Created : 12 Mar 2006 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_muc_log).

-protocol({xep, 334, '0.2'}).

-author('badlop@process-one.net').

-behaviour(gen_server).

-behaviour(gen_mod).

%% API
-export([start/2, stop/1, reload/3,
	 check_access_log/2, add_to_log/5]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 mod_opt_type/1, mod_options/1, depends/2]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("mod_muc_room.hrl").
-include("translate.hrl").

-record(room, {jid, title, subject, subject_author, config}).

-define(PLAINTEXT_CO, <<"ZZCZZ">>).
-define(PLAINTEXT_IN, <<"ZZIZZ">>).
-define(PLAINTEXT_OUT, <<"ZZOZZ">>).

-record(logstate, {host,
		out_dir,
		dir_type,
		dir_name,
		file_format,
		file_permissions,
		css_file,
		access,
		lang,
		timezone,
		spam_prevention,
		top_link}).

%%====================================================================
%% API
%%====================================================================
start(Host, Opts) ->
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    gen_mod:stop_child(?MODULE, Host).

reload(Host, NewOpts, _OldOpts) ->
    Proc = get_proc_name(Host),
    gen_server:cast(Proc, {reload, NewOpts}).

add_to_log(Host, Type, Data, Room, Opts) ->
    gen_server:cast(get_proc_name(Host),
		    {add_to_log, Type, Data, Room, Opts}).

check_access_log(Host, From) ->
    case catch gen_server:call(get_proc_name(Host),
			       {check_access_log, Host, From})
	of
      {'EXIT', _Error} -> deny;
      Res -> Res
    end.

depends(_Host, _Opts) ->
    [{mod_muc, hard}].

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Host|_]) ->
    process_flag(trap_exit, true),
    Opts = gen_mod:get_module_opts(Host, ?MODULE),
    {ok, init_state(Host, Opts)}.

handle_call({check_access_log, ServerHost, FromJID}, _From, State) ->
    Reply = acl:match_rule(ServerHost, State#logstate.access, FromJID),
    {reply, Reply, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({reload, Opts}, #logstate{host = Host}) ->
    {noreply, init_state(Host, Opts)};
handle_cast({add_to_log, Type, Data, Room, Opts}, State) ->
    case catch add_to_log2(Type, Data, Room, Opts, State) of
      {'EXIT', Reason} -> ?ERROR_MSG("~p", [Reason]);
      _ -> ok
    end,
    {noreply, State};
handle_cast(Msg, State) ->
    ?WARNING_MSG("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
init_state(Host, Opts) ->
    OutDir = mod_muc_log_opt:outdir(Opts),
    DirType = mod_muc_log_opt:dirtype(Opts),
    DirName = mod_muc_log_opt:dirname(Opts),
    FileFormat = mod_muc_log_opt:file_format(Opts),
    FilePermissions = mod_muc_log_opt:file_permissions(Opts),
    CSSFile = mod_muc_log_opt:cssfile(Opts),
    AccessLog = mod_muc_log_opt:access_log(Opts),
    Timezone = mod_muc_log_opt:timezone(Opts),
    Top_link = mod_muc_log_opt:top_link(Opts),
    NoFollow = mod_muc_log_opt:spam_prevention(Opts),
    Lang = ejabberd_option:language(Host),
    #logstate{host = Host, out_dir = OutDir,
	      dir_type = DirType, dir_name = DirName,
	      file_format = FileFormat, css_file = CSSFile,
	      file_permissions = FilePermissions,
	      access = AccessLog, lang = Lang, timezone = Timezone,
	      spam_prevention = NoFollow, top_link = Top_link}.

put_header_xml(F, Room, Date) ->
    {Y, M, D} = Date,
    DateString = io_lib:format("~4..0w-~2..0w-~2..0w", [Y, M, D]),
    Header = io_lib:format("<muclog xmlns='https://ejabberd.im/muclog' roomjid='~s' date='~s'>\n",
                          [ xmlize(Room#room.jid), DateString ]),
    file:write(F, Header),
    % TODO: write current room config + current occupants + current subject?
    ok.

add_to_log_xml(Nick, Packet, RoomJID, Opts, State) ->
    #logstate{out_dir = OutDir, dir_type = DirType,
	      dir_name = DirName,
	      file_permissions = FilePermissions,
	      timezone = Timezone} =
	State,
    Room = get_room_info(RoomJID, Opts),
    Now = p1_time_compat:timestamp(),
    Addresses = #addresses{
                   list = [#address{type = ofrom,
                                    jid = xmpp:get_from(Packet)}]},
    AddrPacket = xmpp:set_subtag(Packet, Addresses),
    TSPacket = misc:add_delay_info(
                 AddrPacket, RoomJID, Now),
    SPacket = xmpp:set_from_to(
                TSPacket,
                jid:replace_resource(RoomJID, Nick),
                RoomJID),
    TimeStamp = case Timezone of
		  local -> calendar:now_to_local_time(Now);
		  universal -> calendar:now_to_universal_time(Now)
		end,
    {Fd, Fn, _Dir} = build_filename_string(TimeStamp,
					   OutDir, Room#room.jid, DirType,
					   DirName, xml),
    {Date, _Time} = TimeStamp,
    case file:read_file_info(Fn) of
      {ok, _} -> {ok, F} = file:open(Fn, [append]);
      {error, enoent} ->
	  make_dir_rec(Fd),
	  {ok, F} = file:open(Fn, [append]),
	  catch set_filemode(Fn, FilePermissions),
	  put_header_xml(F, Room, Date),
	  TimeStampYesterday = get_timestamp_daydiff(TimeStamp,
						     -1),
	  {_FdYesterday, FnYesterday, _DatePrev} =
	      build_filename_string(TimeStampYesterday, OutDir,
				    Room#room.jid, DirType, DirName,
				    xml),
	  close_previous_log(FnYesterday, "", xml)
    end,
    case catch file:write(F, [fxml:element_to_binary(xmpp:encode(SPacket, <<"https://ejabberd.im/muclog">>))] ++ <<"\n">>) of
      {'EXIT', Reason} -> ?ERROR_MSG("~p", [Reason]);
      _ -> ok
    end,
    file:close(F),
    ok.

make_roomconfig_element(Room, NewConfig) ->
    #iq{
       type = set, to = Room, from = Room,
       sub_els = [#muc_owner { config = NewConfig } ]
      }.

add_to_log2(text, {Nick, Packet}, Room, Opts, State) ->
    case has_no_permanent_store_hint(Packet) of
	false ->
            case State#logstate.file_format of
                xml ->
                    add_to_log_xml(Nick, Packet, Room, Opts, State);
                _ ->
                    case {Packet#message.subject, Packet#message.body} of
                        {[], []} -> ok;
                        {[], Body} ->
                            Message = {body, xmpp:get_text(Body)},
                            add_message_to_log(Nick, Message, Room, Opts, State);
                        {Subj, _} ->
                            Message = {subject, xmpp:get_text(Subj)},
                            add_message_to_log(Nick, Message, Room, Opts, State)
                    end
            end;
	true -> ok
    end;
add_to_log2(roomconfig_change, {_Occupants, NewConfig}, Room, Opts,
	    State) ->
    case State#logstate.file_format of
        xml ->
            Packet = make_roomconfig_element(Room, NewConfig),
            add_to_log_xml(<<"">>, Packet, Room, Opts, State);
        _ ->
            add_message_to_log(<<"">>, roomconfig_change, Room,
                               Opts, State)
    end;
add_to_log2(roomconfig_change_enabledlogging, {Occupants, NewConfig},
	    Room, Opts, State) ->
    case State#logstate.file_format of
        xml ->
            Packet = make_roomconfig_element(Room, NewConfig),
            add_to_log_xml(<<"">>, Packet, Room, Opts, State);
        _ ->
            add_message_to_log(<<"">>,
                               {roomconfig_change, Occupants}, Room, Opts, State)
    end;
add_to_log2(room_existence, NewStatus, Room, Opts,
	    State) ->
    case State#logstate.file_format of
        xml ->
            Element = #xmlel{name = <<"status">>, attrs =
                                 [{<<"xmlns">>, <<"https://ejabberd.im/muclog">>},
                                  {<<"status">>, atom_to_binary(NewStatus, utf8)}]},
            Packet = #iq{ type = set, to = Room, from = Room,
                          sub_els = [Element]},
            add_to_log_xml(<<"">>, Packet, Room, Opts, State);
        _ ->
            add_message_to_log(<<"">>, {room_existence, NewStatus},
                               Room, Opts, State)
    end;
add_to_log2(nickchange, {OldNick, NewNick, Packet, SendOldUnavailable}, Room, Opts,
	    State) ->
    case State#logstate.file_format of
        xml ->
            if SendOldUnavailable ->
                    Packet1 = #presence{
                                 from = xmpp:get_from(Packet),
                                 type = unavailable,
                                 sub_els = [#muc_user{
                                               items = [#muc_item{nick = NewNick}],
                                               status_codes = [303]}]},
                    add_to_log_xml(OldNick, Packet1, Room, Opts, State);
               true -> ok
            end,
            add_to_log_xml(NewNick, Packet, Room, Opts, State);
        _ ->
            add_message_to_log(NewNick, {nickchange, OldNick}, Room,
                               Opts, State)
    end;
add_to_log2(join, {Nick, Packet}, Room, Opts, State) ->
    case State#logstate.file_format of
        xml ->
            add_to_log_xml(Nick, Packet, Room, Opts, State);
        _ ->
            add_message_to_log(Nick, join, Room, Opts, State)
    end;
add_to_log2(leave, {Nick, Reason, Packet}, Room, Opts, State) ->
    case State#logstate.file_format of
        xml ->
            add_to_log_xml(Nick, Packet, Room, Opts, State);
        _ ->
            case Reason of
                <<"">> ->
                    add_message_to_log(Nick, leave, Room, Opts, State);
                _ ->
                    add_message_to_log(Nick, {leave, Reason}, Room, Opts,
                                       State)
            end
    end;
add_to_log2(kickban, {Nick, Reason, Code, JID, NewAffiliation, ActorJID, ActorNick}, Room, Opts,
	    State) ->
    case State#logstate.file_format of
        xml ->
            Item = #muc_item{affiliation = NewAffiliation,
                             role = none,
                             reason = Reason,
                             actor = #muc_actor{jid = ActorJID, nick = ActorNick}},
            Packet = #presence{from = JID,
                               type = unavailable,
                               sub_els = [#muc_user{items = [Item],
                                                    status_codes = [Code]}]},
            add_to_log_xml(Nick, Packet, Room, Opts, State);
        _ ->
            add_message_to_log(Nick, {kickban, Code, Reason}, Room,
                               Opts, State)
    end.

%%----------------------------------------------------------------------
%% Core

build_filename_string(TimeStamp, OutDir, RoomJID,
		      DirType, DirName, FileFormat) ->
    {{Year, Month, Day}, _Time} = TimeStamp,
    {Dir, Filename, Rel} = case DirType of
			     subdirs ->
				 SYear =
				     (str:format("~4..0w",
								    [Year])),
				 SMonth =
				     (str:format("~2..0w",
								    [Month])),
				 SDay = (str:format("~2..0w",
								       [Day])),
				 {fjoin([SYear, SMonth]), SDay,
				  <<"../..">>};
			     plain ->
				 Date =
				     (str:format("~4..0w-~2..0w-~2..0w",
								    [Year,
								     Month,
								     Day])),
				 {<<"">>, Date, <<".">>}
			   end,
    RoomString = case DirName of
		   room_jid -> RoomJID;
		   room_name -> get_room_name(RoomJID)
		 end,
    Extension = case FileFormat of
		  html -> <<".html">>;
		  plaintext -> <<".txt">>;
		  xml -> <<".xml">>
		end,
    Fd = fjoin([OutDir, RoomString, Dir]),
    Fn = fjoin([Fd, <<Filename/binary, Extension/binary>>]),
    Fnrel = fjoin([Rel, Dir, <<Filename/binary, Extension/binary>>]),
    {Fd, Fn, Fnrel}.

get_room_name(RoomJID) ->
    JID = jid:decode(RoomJID), JID#jid.user.

%% calculate day before
get_timestamp_daydiff(TimeStamp, Daydiff) ->
    {Date1, HMS} = TimeStamp,
    Date2 =
	calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(Date1)
					  + Daydiff),
    {Date2, HMS}.

%% Try to close the previous day log, if it exists
close_previous_log(Fn, Images_dir, FileFormat) ->
    case file:read_file_info(Fn) of
      {ok, _} ->
	  {ok, F} = file:open(Fn, [append]),
	  write_last_lines(F, Images_dir, FileFormat),
	  file:close(F);
      _ -> ok
    end.

write_last_lines(_, _, plaintext) -> ok;
write_last_lines(F, _, xml) ->
    file:write(F, <<"</muclog>\n">>);
write_last_lines(F, Images_dir, _FileFormat) ->
    fw(F, <<"<div class=\"legend\">">>),
    fw(F,
       <<"  <a href=\"http://www.ejabberd.im\"><img "
	 "style=\"border:0\" src=\"~s/powered-by-ejabbe"
	 "rd.png\" alt=\"Powered by ejabberd - robust, scalable and extensible XMPP server\"/></a>">>,
       [Images_dir]),
    fw(F,
       <<"  <a href=\"http://www.erlang.org/\"><img "
	 "style=\"border:0\" src=\"~s/powered-by-erlang"
	 ".png\" alt=\"Powered by Erlang\"/></a>">>,
       [Images_dir]),
    fw(F, <<"<span class=\"w3c\">">>),
    fw(F,
       <<"  <a href=\"http://validator.w3.org/check?uri"
	 "=referer\"><img style=\"border:0;width:88px;h"
	 "eight:31px\" src=\"~s/valid-xhtml10.png\" "
	 "alt=\"Valid XHTML 1.0 Transitional\" "
	 "/></a>">>,
       [Images_dir]),
    fw(F,
       <<"  <a href=\"http://jigsaw.w3.org/css-validato"
	 "r/\"><img style=\"border:0;width:88px;height:"
	 "31px\" src=\"~s/vcss.png\" alt=\"Valid "
	 "CSS!\"/></a>">>,
       [Images_dir]),
    fw(F, <<"</span></div></body></html>">>).

set_filemode(Fn, {FileMode, FileGroup}) ->
    ok = file:change_mode(Fn, list_to_integer(integer_to_list(FileMode), 8)),
    ok = file:change_group(Fn, FileGroup).

htmlize_nick(Nick1, html) ->
    htmlize(<<"<", Nick1/binary, ">">>, html);
htmlize_nick(Nick1, plaintext) ->
    htmlize(<<?PLAINTEXT_IN/binary, Nick1/binary, ?PLAINTEXT_OUT/binary>>, plaintext).

add_message_to_log(Nick1, Message, RoomJID, Opts,
		   State) ->
    #logstate{out_dir = OutDir, dir_type = DirType,
	      dir_name = DirName, file_format = FileFormat,
	      file_permissions = FilePermissions,
	      css_file = CSSFile, lang = Lang, timezone = Timezone,
	      spam_prevention = NoFollow, top_link = TopLink} =
	State,
    Room = get_room_info(RoomJID, Opts),
    Nick = htmlize(Nick1, FileFormat),
    Nick2 = htmlize_nick(Nick1, FileFormat),
    Now = erlang:timestamp(),
    TimeStamp = case Timezone of
		  local -> calendar:now_to_local_time(Now);
		  universal -> calendar:now_to_universal_time(Now)
		end,
    {Fd, Fn, _Dir} = build_filename_string(TimeStamp,
					   OutDir, Room#room.jid, DirType,
					   DirName, FileFormat),
    {Date, Time} = TimeStamp,
    case file:read_file_info(Fn) of
      {ok, _} -> {ok, F} = file:open(Fn, [append]);
      {error, enoent} ->
	  make_dir_rec(Fd),
	  {ok, F} = file:open(Fn, [append]),
	  catch set_filemode(Fn, FilePermissions),
	  Datestring = get_dateweek(Date, Lang),
	  TimeStampYesterday = get_timestamp_daydiff(TimeStamp,
						     -1),
	  {_FdYesterday, FnYesterday, DatePrev} =
	      build_filename_string(TimeStampYesterday, OutDir,
				    Room#room.jid, DirType, DirName,
				    FileFormat),
	  TimeStampTomorrow = get_timestamp_daydiff(TimeStamp, 1),
	  {_FdTomorrow, _FnTomorrow, DateNext} =
	      build_filename_string(TimeStampTomorrow, OutDir,
				    Room#room.jid, DirType, DirName,
				    FileFormat),
	  HourOffset = calc_hour_offset(TimeStamp),
	  put_header(F, Room, Datestring, CSSFile, Lang,
		     HourOffset, DatePrev, DateNext, TopLink, FileFormat),
	  Images_dir = fjoin([OutDir, <<"images">>]),
	  file:make_dir(Images_dir),
	  create_image_files(Images_dir),
	  Images_url = case DirType of
			 subdirs -> <<"../../../images">>;
			 plain -> <<"../images">>
		       end,
	  close_previous_log(FnYesterday, Images_url, FileFormat)
    end,
    Text = case Message of
	     roomconfig_change ->
		 RoomConfig = roomconfig_to_string(Room#room.config,
						   Lang, FileFormat),
		 put_room_config(F, RoomConfig, Lang, FileFormat),
		 io_lib:format("<font class=\"mrcm\">~s</font><br/>",
			       [tr(Lang, ?T("Chatroom configuration modified"))]);
	     {roomconfig_change, Occupants} ->
		 RoomConfig = roomconfig_to_string(Room#room.config,
						   Lang, FileFormat),
		 put_room_config(F, RoomConfig, Lang, FileFormat),
		 RoomOccupants = roomoccupants_to_string(Occupants,
							 FileFormat),
		 put_room_occupants(F, RoomOccupants, Lang, FileFormat),
		 io_lib:format("<font class=\"mrcm\">~s</font><br/>",
			       [tr(Lang, ?T("Chatroom configuration modified"))]);
	     join ->
		 io_lib:format("<font class=\"mj\">~s ~s</font><br/>",
			       [Nick, tr(Lang, ?T("joins the room"))]);
	     leave ->
		 io_lib:format("<font class=\"ml\">~s ~s</font><br/>",
			       [Nick, tr(Lang, ?T("leaves the room"))]);
	     {leave, Reason} ->
		 io_lib:format("<font class=\"ml\">~s ~s: ~s</font><br/>",
			       [Nick, tr(Lang, ?T("leaves the room")),
				htmlize(Reason, NoFollow, FileFormat)]);
	     {kickban, 301, <<"">>} ->
		 io_lib:format("<font class=\"mb\">~s ~s</font><br/>",
			       [Nick, tr(Lang, ?T("has been banned"))]);
	     {kickban, 301, Reason} ->
		 io_lib:format("<font class=\"mb\">~s ~s: ~s</font><br/>",
			       [Nick, tr(Lang, ?T("has been banned")),
				htmlize(Reason, FileFormat)]);
	     {kickban, 307, <<"">>} ->
		 io_lib:format("<font class=\"mk\">~s ~s</font><br/>",
			       [Nick, tr(Lang, ?T("has been kicked"))]);
	     {kickban, 307, Reason} ->
		 io_lib:format("<font class=\"mk\">~s ~s: ~s</font><br/>",
			       [Nick, tr(Lang, ?T("has been kicked")),
				htmlize(Reason, FileFormat)]);
	     {kickban, 321, <<"">>} ->
		 io_lib:format("<font class=\"mk\">~s ~s</font><br/>",
			       [Nick,
				tr(Lang, ?T("has been kicked because of an affiliation "
					    "change"))]);
	     {kickban, 322, <<"">>} ->
		 io_lib:format("<font class=\"mk\">~s ~s</font><br/>",
			       [Nick,
				tr(Lang, ?T("has been kicked because the room has "
					    "been changed to members-only"))]);
	     {kickban, 332, <<"">>} ->
		 io_lib:format("<font class=\"mk\">~s ~s</font><br/>",
			       [Nick,
				tr(Lang, ?T("has been kicked because of a system "
					    "shutdown"))]);
	     {nickchange, OldNick} ->
		 io_lib:format("<font class=\"mnc\">~s ~s ~s</font><br/>",
			       [htmlize(OldNick, FileFormat),
				tr(Lang, ?T("is now known as")), Nick]);
	     {subject, T} ->
		 io_lib:format("<font class=\"msc\">~s~s~s</font><br/>",
			       [Nick, tr(Lang, ?T(" has set the subject to: ")),
				htmlize(T, NoFollow, FileFormat)]);
	     {body, T} ->
		 case {ejabberd_regexp:run(T, <<"^/me ">>), Nick} of
		   {_, <<"">>} ->
		       io_lib:format("<font class=\"msm\">~s</font><br/>",
				     [htmlize(T, NoFollow, FileFormat)]);
		   {match, _} ->
		       io_lib:format("<font class=\"mne\">~s ~s</font><br/>",
				     [Nick,
				      str:substr(htmlize(T, FileFormat), 5)]);
		   {nomatch, _} ->
		       io_lib:format("<font class=\"mn\">~s</font> ~s<br/>",
				     [Nick2, htmlize(T, NoFollow, FileFormat)])
		 end;
	     {room_existence, RoomNewExistence} ->
		 io_lib:format("<font class=\"mrcm\">~s</font><br/>",
			       [get_room_existence_string(RoomNewExistence,
							  Lang)])
	   end,
    {Hour, Minute, Second} = Time,
    STime = io_lib:format("~2..0w:~2..0w:~2..0w",
                          [Hour, Minute, Second]),
    {_, _, Microsecs} = Now,
    STimeUnique = io_lib:format("~s.~w",
				[STime, Microsecs]),
    catch fw(F,
       list_to_binary(
         io_lib:format("<a id=\"~s\" name=\"~s\" href=\"#~s\" "
                       "class=\"ts\">[~s]</a> ",
                       [STimeUnique, STimeUnique, STimeUnique, STime])
	 ++ Text),
       FileFormat),
    file:close(F),
    ok.

%%----------------------------------------------------------------------
%% Utilities

get_room_existence_string(created, Lang) ->
    tr(Lang, ?T("Chatroom is created"));
get_room_existence_string(destroyed, Lang) ->
    tr(Lang, ?T("Chatroom is destroyed"));
get_room_existence_string(started, Lang) ->
    tr(Lang, ?T("Chatroom is started"));
get_room_existence_string(stopped, Lang) ->
    tr(Lang, ?T("Chatroom is stopped")).

get_dateweek(Date, Lang) ->
    Weekday = case calendar:day_of_the_week(Date) of
		1 -> tr(Lang, ?T("Monday"));
		2 -> tr(Lang, ?T("Tuesday"));
		3 -> tr(Lang, ?T("Wednesday"));
		4 -> tr(Lang, ?T("Thursday"));
		5 -> tr(Lang, ?T("Friday"));
		6 -> tr(Lang, ?T("Saturday"));
		7 -> tr(Lang, ?T("Sunday"))
	      end,
    {Y, M, D} = Date,
    Month = case M of
	      1 -> tr(Lang, ?T("January"));
	      2 -> tr(Lang, ?T("February"));
	      3 -> tr(Lang, ?T("March"));
	      4 -> tr(Lang, ?T("April"));
	      5 -> tr(Lang, ?T("May"));
	      6 -> tr(Lang, ?T("June"));
	      7 -> tr(Lang, ?T("July"));
	      8 -> tr(Lang, ?T("August"));
	      9 -> tr(Lang, ?T("September"));
	      10 -> tr(Lang, ?T("October"));
	      11 -> tr(Lang, ?T("November"));
	      12 -> tr(Lang, ?T("December"))
	    end,
    list_to_binary(
      case Lang of
          <<"en">> ->
              io_lib:format("~s, ~s ~w, ~w", [Weekday, Month, D, Y]);
          <<"es">> ->
              io_lib:format("~s ~w de ~s de ~w",
                            [Weekday, D, Month, Y]);
          _ ->
              io_lib:format("~s, ~w ~s ~w", [Weekday, D, Month, Y])
      end).

make_dir_rec(Dir) ->
    filelib:ensure_dir(<<Dir/binary, $/>>).

%% {ok, F1}=file:open("valid-xhtml10.png", [read]).
%% {ok, F1b}=file:read(F1, 1000000).
%% c("../../ejabberd/src/jlib.erl").
%% base64:encode(F1b).

create_image_files(Images_dir) ->
    Filenames = [<<"powered-by-ejabberd.png">>,
		 <<"powered-by-erlang.png">>, <<"valid-xhtml10.png">>,
		 <<"vcss.png">>],
    lists:foreach(
      fun(Filename) ->
	      Src = filename:join([misc:img_dir(), Filename]),
	      Dst = fjoin([Images_dir, Filename]),
	      case file:copy(Src, Dst) of
		  {ok, _} -> ok;
		  {error, Why} ->
		      ?ERROR_MSG("Failed to copy ~s to ~s: ~s",
				 [Src, Dst, file:format_error(Why)])
	      end
      end, Filenames).

fw(F, S) -> fw(F, S, [], html).

fw(F, S, O) when is_list(O) -> fw(F, S, O, html);
fw(F, S, FileFormat) when is_atom(FileFormat) ->
    fw(F, S, [], FileFormat).

fw(F, S, O, FileFormat) ->
    S1 = (str:format(binary_to_list(S) ++ "~n", O)),
    S2 = case FileFormat of
	     html ->
		 S1;
	     plaintext ->
		 S1a = ejabberd_regexp:greplace(S1, <<"<[^<^>]*>">>, <<"">>),
		 S1x = ejabberd_regexp:greplace(S1a, ?PLAINTEXT_CO, <<"~~">>),
		 S1y = ejabberd_regexp:greplace(S1x, ?PLAINTEXT_IN, <<"<">>),
		 ejabberd_regexp:greplace(S1y, ?PLAINTEXT_OUT, <<">">>)
	 end,
    file:write(F, S2).

put_header(_, _, _, _, _, _, _, _, _, plaintext) -> ok;
put_header(F, Room, Date, CSSFile, Lang, Hour_offset,
	   Date_prev, Date_next, Top_link, FileFormat) ->
    fw(F,
       <<"<!DOCTYPE html PUBLIC \"-//W3C//DTD "
	 "XHTML 1.0 Transitional//EN\" \"http://www.w3."
	 "org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">">>),
    fw(F,
       <<"<html xmlns=\"http://www.w3.org/1999/xhtml\" "
	 "xml:lang=\"~s\" lang=\"~s\">">>,
       [Lang, Lang]),
    fw(F, <<"<head>">>),
    fw(F,
       <<"<meta http-equiv=\"Content-Type\" content=\"t"
	 "ext/html; charset=utf-8\" />">>),
    fw(F, <<"<title>~s - ~s</title>">>,
       [htmlize(Room#room.title), Date]),
    put_header_css(F, CSSFile),
    put_header_script(F),
    fw(F, <<"</head>">>),
    fw(F, <<"<body>">>),
    {Top_url, Top_text} = Top_link,
    fw(F,
       <<"<div style=\"text-align: right;\"><a "
	 "style=\"color: #AAAAAA; font-family: "
	 "monospace; text-decoration: none; font-weight"
	 ": bold;\" href=\"~s\">~s</a></div>">>,
       [Top_url, Top_text]),
    fw(F, <<"<div class=\"roomtitle\">~s</div>">>,
       [htmlize(Room#room.title)]),
    fw(F,
       <<"<a class=\"roomjid\" href=\"xmpp:~s?join\">~s"
	 "</a>">>,
       [Room#room.jid, Room#room.jid]),
    fw(F,
       <<"<div class=\"logdate\">~s<span class=\"w3c\">"
	 "<a class=\"nav\" href=\"~s\">&lt;</a> "
	 "<a class=\"nav\" href=\"./\">^</a> <a "
	 "class=\"nav\" href=\"~s\">&gt;</a></span></di"
	 "v>">>,
       [Date, Date_prev, Date_next]),
    case {htmlize(Room#room.subject_author),
	  htmlize(Room#room.subject)}
	of
      {<<"">>, <<"">>} -> ok;
      {SuA, Su} ->
	  fw(F, <<"<div class=\"roomsubject\">~s~s~s</div>">>,
	     [SuA, tr(Lang, ?T(" has set the subject to: ")), Su])
    end,
    RoomConfig = roomconfig_to_string(Room#room.config,
				      Lang, FileFormat),
    put_room_config(F, RoomConfig, Lang, FileFormat),
    Occupants = get_room_occupants(Room#room.jid),
    RoomOccupants = roomoccupants_to_string(Occupants,
					    FileFormat),
    put_room_occupants(F, RoomOccupants, Lang, FileFormat),
    Time_offset_str = case Hour_offset < 0 of
			true -> io_lib:format("~p", [Hour_offset]);
			false -> io_lib:format("+~p", [Hour_offset])
		      end,
    fw(F, <<"<br/><a class=\"ts\">GMT~s</a><br/>">>,
       [Time_offset_str]).

put_header_css(F, {file, Path}) ->
    fw(F, <<"<style type=\"text/css\">">>),
    fw(F, <<"<!--">>),
    case file:read_file(Path) of
	{ok, Data} -> fw(F, Data);
	{error, _} -> ok
    end,
    fw(F, <<"//-->">>),
    fw(F, <<"</style>">>);
put_header_css(F, {url, URL}) ->
    fw(F,
       <<"<link rel=\"stylesheet\" type=\"text/css\" "
	 "href=\"~s\" media=\"all\">">>,
       [URL]).

put_header_script(F) ->
    fw(F, <<"<script type=\"text/javascript\">">>),
    case misc:read_js("muc.js") of
	{ok, Data} -> fw(F, Data);
	{error, _} -> ok
    end,
    fw(F, <<"</script>">>).

put_room_config(_F, _RoomConfig, _Lang, plaintext) ->
    ok;
put_room_config(F, RoomConfig, Lang, _FileFormat) ->
    {_, Now2, _} = erlang:timestamp(),
    fw(F, <<"<div class=\"rc\">">>),
    fw(F,
       <<"<div class=\"rct\" onclick=\"sh('a~p');return "
	 "false;\">~s</div>">>,
       [Now2, tr(Lang, ?T("Room Configuration"))]),
    fw(F,
       <<"<div class=\"rcos\" id=\"a~p\" style=\"displa"
	 "y: none;\" ><br/>~s</div>">>,
       [Now2, RoomConfig]),
    fw(F, <<"</div>">>).

put_room_occupants(_F, _RoomOccupants, _Lang,
		   plaintext) ->
    ok;
put_room_occupants(F, RoomOccupants, Lang,
		   _FileFormat) ->
    {_, Now2, _} = erlang:timestamp(),
%% htmlize
%% The default behaviour is to ignore the nofollow spam prevention on links
%% (NoFollow=false)
    fw(F, <<"<div class=\"rc\">">>),
    fw(F,
       <<"<div class=\"rct\" onclick=\"sh('o~p');return "
	 "false;\">~s</div>">>,
       [Now2, tr(Lang, ?T("Room Occupants"))]),
    fw(F,
       <<"<div class=\"rcos\" id=\"o~p\" style=\"displa"
	 "y: none;\" ><br/>~s</div>">>,
       [Now2, RoomOccupants]),
    fw(F, <<"</div>">>).

htmlize(S1) -> htmlize(S1, html).

htmlize(S1, plaintext) ->
    ejabberd_regexp:greplace(S1, <<"~">>, ?PLAINTEXT_CO);
htmlize(S1, FileFormat) ->
    htmlize(S1, false, FileFormat).

%% The NoFollow parameter tell if the spam prevention should be applied to the link found
%% true means 'apply nofollow on links'.
htmlize(S0, _NoFollow, plaintext) ->
    S1  = ejabberd_regexp:greplace(S0, <<"~">>, ?PLAINTEXT_CO),
    S1x = ejabberd_regexp:greplace(S1, <<"<">>, ?PLAINTEXT_IN),
    ejabberd_regexp:greplace(S1x, <<">">>, ?PLAINTEXT_OUT);
htmlize(S1, NoFollow, _FileFormat) ->
    S2_list = str:tokens(S1, <<"\n">>),
    lists:foldl(fun (Si, Res) ->
			Si2 = htmlize2(Si, NoFollow),
			case Res of
			  <<"">> -> Si2;
			  _ -> <<Res/binary, "<br/>", Si2/binary>>
			end
		end,
		<<"">>, S2_list).

htmlize2(S1, NoFollow) ->
%% Regexp link
%% Add the nofollow rel attribute when required
    S2 = ejabberd_regexp:greplace(S1, <<"\\&">>,
				  <<"\\&amp;">>),
    S3 = ejabberd_regexp:greplace(S2, <<"<">>,
				  <<"\\&lt;">>),
    S4 = ejabberd_regexp:greplace(S3, <<">">>,
				  <<"\\&gt;">>),
    S5 = ejabberd_regexp:greplace(S4,
				  <<"((http|https|ftp)://|(mailto|xmpp):)[^] "
				    ")'\"}]+">>,
				  link_regexp(NoFollow)),
    S6 = ejabberd_regexp:greplace(S5, <<"  ">>,
				  <<"\\&nbsp;\\&nbsp;">>),
    S7 = ejabberd_regexp:greplace(S6, <<"\\t">>,
				  <<"\\&nbsp;\\&nbsp;\\&nbsp;\\&nbsp;">>),
    S8 = ejabberd_regexp:greplace(S7, <<"~">>,
				  <<"~~">>),
    ejabberd_regexp:greplace(S8, <<226, 128, 174>>,
			     <<"[RLO]">>).

xmlize(S1) ->
    S2 = ejabberd_regexp:greplace(S1, <<"\\&">>, <<"\\&amp;">>),
    S3 = ejabberd_regexp:greplace(S2, <<"<">>, <<"\\&lt;">>),
    S4 = ejabberd_regexp:greplace(S3, <<">">>, <<"\\&gt;">>),
    ejabberd_regexp:greplace(S4, <<"'">>, <<"\\&apos;">>).

link_regexp(false) -> <<"<a href=\"&\">&</a>">>;
link_regexp(true) ->
    <<"<a href=\"&\" rel=\"nofollow\">&</a>">>.

get_room_info(RoomJID, Opts) ->
    Title = case lists:keysearch(title, 1, Opts) of
	      {value, {_, T}} -> T;
	      false -> <<"">>
	    end,
    Subject = case lists:keysearch(subject, 1, Opts) of
		{value, {_, S}} -> xmpp:get_text(S);
		false -> <<"">>
	      end,
    SubjectAuthor = case lists:keysearch(subject_author, 1,
					 Opts)
			of
		      {value, {_, SA}} -> SA;
		      false -> <<"">>
		    end,
    #room{jid = jid:encode(RoomJID), title = Title,
	  subject = Subject, subject_author = SubjectAuthor,
	  config = Opts}.

roomconfig_to_string(Options, Lang, FileFormat) ->
    Title = case lists:keysearch(title, 1, Options) of
	      {value, Tuple} -> [Tuple];
	      false -> []
	    end,
    Os1 = lists:keydelete(title, 1, Options),
    Os2 = lists:sort(Os1),
    Options2 = Title ++ Os2,
    lists:foldl(fun ({Opt, Val}, R) ->
			case get_roomconfig_text(Opt, Lang) of
			  undefined -> R;
			  OptText ->
			      R2 = case Val of
				     false ->
					 <<"<div class=\"rcod\">",
					   OptText/binary, "</div>">>;
				     true ->
					 <<"<div class=\"rcoe\">",
					   OptText/binary, "</div>">>;
				     <<"">> ->
					 <<"<div class=\"rcod\">",
					   OptText/binary, "</div>">>;
				     T ->
					 case Opt of
					   password ->
					       <<"<div class=\"rcoe\">",
						 OptText/binary, "</div>">>;
					   max_users ->
					       <<"<div class=\"rcot\">",
						 OptText/binary, ": \"",
						 (htmlize(integer_to_binary(T),
							  FileFormat))/binary,
						 "\"</div>">>;
					   title ->
					       <<"<div class=\"rcot\">",
						 OptText/binary, ": \"",
						 (htmlize(T,
							  FileFormat))/binary,
						 "\"</div>">>;
					   description ->
					       <<"<div class=\"rcot\">",
						 OptText/binary, ": \"",
						 (htmlize(T,
							  FileFormat))/binary,
						 "\"</div>">>;
					   allow_private_messages_from_visitors ->
					       <<"<div class=\"rcot\">",
						 OptText/binary, ": \"",
						 (htmlize(tr(Lang, misc:atom_to_binary(T)),
							  FileFormat))/binary,
						 "\"</div>">>;
					   _ -> <<"\"", T/binary, "\"">>
					 end
				   end,
			      <<R/binary, R2/binary>>
			end
		end,
		<<"">>, Options2).

get_roomconfig_text(title, Lang) -> tr(Lang, ?T("Room title"));
get_roomconfig_text(persistent, Lang) ->
    tr(Lang, ?T("Make room persistent"));
get_roomconfig_text(public, Lang) ->
    tr(Lang, ?T("Make room public searchable"));
get_roomconfig_text(public_list, Lang) ->
    tr(Lang, ?T("Make participants list public"));
get_roomconfig_text(password_protected, Lang) ->
    tr(Lang, ?T("Make room password protected"));
get_roomconfig_text(password, Lang) -> tr(Lang, ?T("Password"));
get_roomconfig_text(anonymous, Lang) ->
    tr(Lang, ?T("This room is not anonymous"));
get_roomconfig_text(members_only, Lang) ->
    tr(Lang, ?T("Make room members-only"));
get_roomconfig_text(moderated, Lang) ->
    tr(Lang, ?T("Make room moderated"));
get_roomconfig_text(members_by_default, Lang) ->
    tr(Lang, ?T("Default users as participants"));
get_roomconfig_text(allow_change_subj, Lang) ->
    tr(Lang, ?T("Allow users to change the subject"));
get_roomconfig_text(allow_private_messages, Lang) ->
    tr(Lang, ?T("Allow users to send private messages"));
get_roomconfig_text(allow_private_messages_from_visitors, Lang) ->
    tr(Lang, ?T("Allow visitors to send private messages to"));
get_roomconfig_text(allow_query_users, Lang) ->
    tr(Lang, ?T("Allow users to query other users"));
get_roomconfig_text(allow_user_invites, Lang) ->
    tr(Lang, ?T("Allow users to send invites"));
get_roomconfig_text(logging, Lang) -> tr(Lang, ?T("Enable logging"));
get_roomconfig_text(allow_visitor_nickchange, Lang) ->
    tr(Lang, ?T("Allow visitors to change nickname"));
get_roomconfig_text(allow_visitor_status, Lang) ->
    tr(Lang, ?T("Allow visitors to send status text in presence updates"));
get_roomconfig_text(captcha_protected, Lang) ->
    tr(Lang, ?T("Make room CAPTCHA protected"));
get_roomconfig_text(description, Lang) ->
    tr(Lang, ?T("Room description"));
%% get_roomconfig_text(subject, Lang) ->  "Subject";
%% get_roomconfig_text(subject_author, Lang) ->  "Subject author";
get_roomconfig_text(max_users, Lang) ->
    tr(Lang, ?T("Maximum Number of Occupants"));
get_roomconfig_text(_, _) -> undefined.

%% Users = [{JID, Nick, Role}]
roomoccupants_to_string(Users, _FileFormat) ->
    Res = [role_users_to_string(RoleS, Users1)
	   || {RoleS, Users1} <- group_by_role(Users),
	      Users1 /= []],
    iolist_to_binary([<<"<div class=\"rcot\">">>, Res, <<"</div>">>]).

group_by_role(Users) ->
    {Ms, Ps, Vs, Ns} = lists:foldl(fun ({JID, Nick,
					 moderator},
					{Mod, Par, Vis, Non}) ->
					   {[{JID, Nick}] ++ Mod, Par, Vis,
					    Non};
				       ({JID, Nick, participant},
					{Mod, Par, Vis, Non}) ->
					   {Mod, [{JID, Nick}] ++ Par, Vis,
					    Non};
				       ({JID, Nick, visitor},
					{Mod, Par, Vis, Non}) ->
					   {Mod, Par, [{JID, Nick}] ++ Vis,
					    Non};
				       ({JID, Nick, none},
					{Mod, Par, Vis, Non}) ->
					   {Mod, Par, Vis, [{JID, Nick}] ++ Non}
				   end,
				   {[], [], [], []}, Users),
    case Ms of
      [] -> [];
      _ -> [{<<"Moderator">>, Ms}]
    end
      ++
      case Ms of
	[] -> [];
	_ -> [{<<"Participant">>, Ps}]
      end
	++
	case Ms of
	  [] -> [];
	  _ -> [{<<"Visitor">>, Vs}]
	end
	  ++
	  case Ms of
	    [] -> [];
	    _ -> [{<<"None">>, Ns}]
	  end.

role_users_to_string(RoleS, Users) ->
    SortedUsers = lists:keysort(2, Users),
    UsersString = << <<Nick/binary, "<br/>">>
		   || {_JID, Nick} <- SortedUsers >>,
    <<RoleS/binary, ": ", UsersString/binary>>.

get_room_occupants(RoomJIDString) ->
    RoomJID = jid:decode(RoomJIDString),
    RoomName = RoomJID#jid.luser,
    MucService = RoomJID#jid.lserver,
    case get_room_state(RoomName, MucService) of
	{ok, StateData} ->
	    [{U#user.jid, U#user.nick, U#user.role}
	     || U <- maps:values(StateData#state.users)];
	error ->
	    []
    end.

-spec get_room_state(binary(), binary()) -> {ok, mod_muc_room:state()} | error.

get_room_state(RoomName, MucService) ->
    case mod_muc:find_online_room(RoomName, MucService) of
	{ok, RoomPid} ->
	    get_room_state(RoomPid);
	error ->
	    error
    end.

-spec get_room_state(pid()) -> {ok, mod_muc_room:state()} | error.

get_room_state(RoomPid) ->
    case mod_muc_room:get_state(RoomPid) of
	{ok, State} -> {ok, State};
	{error, _} -> error
    end.

get_proc_name(Host) ->
    gen_mod:get_module_proc(Host, ?MODULE).

calc_hour_offset(TimeHere) ->
    TimeZero = calendar:universal_time(),
    TimeHereHour =
	calendar:datetime_to_gregorian_seconds(TimeHere) div
	  3600,
    TimeZeroHour =
	calendar:datetime_to_gregorian_seconds(TimeZero) div
	  3600,
    TimeHereHour - TimeZeroHour.

fjoin(FileList) ->
    list_to_binary(filename:join([binary_to_list(File) || File <- FileList])).

-spec tr(binary(), binary()) -> binary().
tr(Lang, Text) ->
    translate:translate(Lang, Text).

has_no_permanent_store_hint(Packet) ->
    xmpp:has_subtag(Packet, #hint{type = 'no-store'}) orelse
    xmpp:has_subtag(Packet, #hint{type = 'no-storage'}) orelse
    xmpp:has_subtag(Packet, #hint{type = 'no-permanent-store'}) orelse
    xmpp:has_subtag(Packet, #hint{type = 'no-permanent-storage'}).

mod_opt_type(access_log) ->
    econf:acl();
mod_opt_type(cssfile) ->
    econf:url_or_file();
mod_opt_type(dirname) ->
    econf:enum([room_jid, room_name]);
mod_opt_type(dirtype) ->
    econf:enum([subdirs, plain]);
mod_opt_type(file_format) ->
    econf:enum([html, plaintext, xml]);
mod_opt_type(file_permissions) ->
    econf:and_then(
      econf:options(
	#{mode => econf:non_neg_int(),
	  group => econf:non_neg_int()}),
      fun(Opts) ->
	      {proplists:get_value(mode, Opts, 644),
	       proplists:get_value(group, Opts, 33)}
      end);
mod_opt_type(outdir) ->
    econf:directory(write);
mod_opt_type(spam_prevention) ->
    econf:bool();
mod_opt_type(timezone) ->
    econf:enum([local, universal]);
mod_opt_type(top_link) ->
    econf:and_then(
      econf:non_empty(
	econf:map(econf:binary(), econf:binary())),
      fun hd/1).

-spec mod_options(binary()) -> [{top_link, {binary(), binary()}} |
				{file_permissions,
				 {non_neg_integer(), non_neg_integer()}} |
				{atom(), any()}].
mod_options(_) ->
    [{access_log, muc_admin},
     {cssfile, filename:join(misc:css_dir(), <<"muc.css">>)},
     {dirname, room_jid},
     {dirtype, subdirs},
     {file_format, html},
     {file_permissions, {644, 33}},
     {outdir, <<"www/muc">>},
     {spam_prevention, true},
     {timezone, local},
     {top_link, {<<"/">>, <<"Home">>}}].
