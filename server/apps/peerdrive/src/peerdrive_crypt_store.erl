%% PeerDrive
%% Copyright (C) 2012  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
%%
%% This program is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(peerdrive_crypt_store).
-behaviour(gen_server).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2, terminate/2]).
-export([enc_xid/2]).

-include("store.hrl").
-include("cryptstore.hrl").

-record(state, {regid, store, sid, key, synclocks=[]}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public interface
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link(Id, _NoVerify, {Module, ModArg, Pwd}) ->
	RegId = list_to_atom(atom_to_list(Id) ++ "_store"),
	gen_server:start_link({local, RegId}, ?MODULE, {Id, RegId, Module, ModArg, Pwd}, []).

% The length of the Data is unknown. We cannot use stream cipher modes because
% they require unique IVec's for each message. This leaves us with CBC which typically
% doubles the cipher text size. :-(

dec_xid(Key, CipherData) ->
	<<Len:8, Data/binary>> = crypto:aes_cbc_128_decrypt(Key,
		<<"PeerDrivePeerDri">>, CipherData),
	binary_part(Data, 0, Len).


enc_xid(Key, Data) ->
	Size = size(Data),
	Padding = (((Size + 1 + 15) band bnot 15) - Size - 1) * 8,
	ClearData = <<Size:8, Data/binary, 0:Padding>>,
	crypto:aes_cbc_128_encrypt(Key, <<"PeerDrivePeerDri">>, ClearData).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Gen_server callbacks...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({Id, RegId, Module, ModArg, Pwd}) when is_list(Pwd) ->
	init({Id, RegId, Module, ModArg, unicode:characters_to_binary(Pwd)});

init({Id, RegId, Module, ModArg, Pwd}) ->
	ChildId = list_to_atom("real_" ++ atom_to_list(Id)),
	process_flag(trap_exit, true),
	case Module:start_link(ChildId, true, ModArg) of
		{ok, Store} ->
			SId = peerdrive_store:guid(Store),
			S = #state{regid=RegId, store=Store, sid=SId},
			case init_decrypt(Pwd, S) of
				{ok, S2} ->
					init_install_filter(S2),
					{ok, S2};

				unencrypted ->
					case init_create_crypt(Pwd, S) of
						{ok, S2} ->
							init_install_filter(S2),
							{ok, S2};
						{error, Error} ->
							shutdown(Store),
							{stop, Error}
					end;

				{error, Error} ->
					shutdown(Store),
					{stop, Error}
			end;

		ignore ->
			{stop, ignore};
		{error, Error} ->
			{stop, Error}
	end.


handle_call(guid, _From, #state{sid=SId} = S) ->
	{reply, SId, S};

handle_call(statfs, _From, #state{store=Store} = S) ->
	{reply, peerdrive_store:statfs(Store), S};

handle_call({lookup, Doc}, _From, #state{store=Store, key=Key} = S) ->
	Reply = case peerdrive_store:lookup(Store, enc_xid(Key, Doc)) of
		{ok, EncRev, EncPreRevs} ->
			Rev = dec_xid(Key, EncRev),
			PreRevs = [ dec_xid(Key, EncPreRev) || EncPreRev <- EncPreRevs ],
			{ok, Rev, PreRevs};
		error ->
			error
	end,
	{reply, Reply, S};

handle_call({contains, Rev}, _From, #state{store=Store, key=Key} = S) ->
	{reply, peerdrive_store:contains(Store, enc_xid(Key, Rev)), S};

handle_call({stat, Rev}, _From, S) ->
	{reply, do_stat(Rev, S), S};

handle_call({peek, Rev}, {User, _Tag}, S) ->
	{reply, do_peek(Rev, User, S), S};

handle_call({create, Type, Creator}, {User, _Tag}, S) ->
	{reply, do_create(Type, Creator, User, S), S};

handle_call({fork, StartRev, Creator}, {User, _Tag}, S) ->
	{reply, do_fork(StartRev, Creator, User, S), S};

handle_call({update, DId, StartRId, Creator}, {User, _Tag}, S) ->
	{reply, do_update(DId, StartRId, Creator, User, S), S};

handle_call({resume, DId, PreRId, Creator}, {User, _Tag}, S) ->
	{reply, do_resume(DId, PreRId, Creator, User, S), S};

handle_call({forget, DId, PreRId}, _From, #state{store=Store, key=Key} = S) ->
	EncDId = enc_xid(Key, DId),
	EncPreRId = enc_xid(Key, PreRId),
	{reply, peerdrive_store:forget(Store, EncDId, EncPreRId), S};

handle_call({delete_rev, Rev}, _From, #state{store=Store, key=Key} = S) ->
	{reply, peerdrive_store:delete_rev(Store, enc_xid(Key, Rev)), S};

handle_call({delete_doc, Doc, Rev}, _From, #state{store=Store, key=Key} = S) ->
	Reply = peerdrive_store:delete_doc(Store, enc_xid(Key, Doc),
		enc_xid(Key, Rev)),
	{reply, Reply, S};

handle_call({put_doc, Doc, Rev}, {User, _Tag}, S) ->
	{reply, do_put_doc(Doc, Rev, User, S), S};

handle_call({forward_doc, Doc, RevPath, OldPreRId}, {User, _Tag}, S) ->
	{reply, do_forward_doc(Doc, RevPath, OldPreRId, User, S), S};

handle_call({put_rev, Rev, Revision}, {User, _Tag}, S) ->
	{reply, do_put_rev(Rev, Revision, User, S), S};

handle_call({remember_rev, DId, PreRId, OldPreRId}, {User, _}, S) ->
	{reply, do_remember_rev(DId, PreRId, OldPreRId, User, S), S};

handle_call({sync_get_changes, PeerGuid, Anchor}, {From, _Tag}, S) ->
	do_sync_get_changes(PeerGuid, Anchor, From, S);

handle_call({sync_get_anchor, FromSId, ToSId}, _From, S) ->
	{reply, do_sync_get_anchor(FromSId, ToSId, S), S};

handle_call({sync_set_anchor, FromSId, ToSId, SeqNum}, _From, S) ->
	{reply, do_sync_set_anchor(FromSId, ToSId, SeqNum, S), S};

handle_call({sync_finish, PeerGuid}, {From, _Tag}, S) ->
	do_sync_finish(PeerGuid, From, S).


handle_info({'EXIT', From, Reason}, #state{store=Store} = S) ->
	case From of
		Store ->
			% our underlying store died
			{stop, Reason, S#state{store=undefined}};

		_Other ->
			case sync_trap_exit(From, S) of
				error ->
					% must be an associated worker process
					case Reason of
						normal   -> {noreply, S};
						shutdown -> {noreply, S};
						_ ->        {stop, Reason, S}
					end;

				{ok, S2} ->
					% a sync process went away
					{noreply, S2}
			end
	end.


terminate(_Reason, #state{store=undefined}) ->
	ok;

%% We are terminating but our underlying store is still alive. As we're playing
%% supervisor we also have to try to shut down our child.
terminate(_Reason, #state{regid=RegId, store=Store}) ->
	case shutdown(Store) of
		ok ->
			ok;
		{error, Reason} ->
			error_logger:error_report([{peerdrive_crypt_store, RegId},
				{reason, shutdown_error}, {exit_status, Reason}])
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stubs...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

code_change(_, State, _) -> {ok, State}.
handle_cast(_Request, State) -> {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Request handlers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Uses a scheme like LUKS...
%
% ENCR spec structure:
%   "version"   -> 1
%	"cipher"    -> "aes"
%	"hash"      -> "sha1"
%   "mk-digest" -> binary()
%   "mk-salt"   -> binary()
%   "mk-iter"   -> integer()
%   "slots"     -> [Slot]
%   "root"      -> {dlink, EncSId}
%
% Slot structure:
%   "iter"    -> integer()
%   "salt"    -> binary()
%   "enc-key" -> binary()

init_decrypt(Pwd, S) ->
	try
		Spec = read_encr_spec(S#state.store, S#state.sid),
		dict_get(<<"version">>, Spec) == 1 orelse throw({error, enodev}),
		dict_get(<<"cipher">>, Spec) == <<"aes">> orelse throw({error, enodev}),
		dict_get(<<"hash">>, Spec) == <<"sha1">> orelse throw({error, enodev}),
		MkDigest = dict_get(<<"mk-digest">>, Spec),
		MkSalt = dict_get(<<"mk-salt">>, Spec),
		MkIter = dict_get(<<"mk-iter">>, Spec),
		Verify = fun(Key) -> pbkdf2(Key, MkSalt, MkIter) == MkDigest end,
		Key = open_slot(Pwd, Verify, dict_get(<<"slots">>, Spec)),
		{ok, S#state{key=Key}}
	catch
		throw:Error -> Error
	end.


read_encr_spec(Store, Doc) ->
	{ok, Rev, _PreRevs} = check(peerdrive_store:lookup(Store, Doc)),
	{ok, Handle} = check(peerdrive_store:peek(Store, Rev)),
	try
		case peerdrive_store:read(Handle, <<"ENCR">>, 0, 16#100000) of
			{ok, Data} ->
				case catch peerdrive_struct:decode(Data) of
					{'EXIT', _Reason} ->
						throw({error, eio});
					Struct ->
						Struct
				end;

			{error, enoent} ->
				throw(unencrypted);
			{error, _} = Error ->
				throw(Error)
		end
	after
		peerdrive_store:close(Handle)
	end.


open_slot(_Pwd, _Verify, []) ->
	throw({error, eperm});

open_slot(Pwd, Verify, [Slot | Rest]) ->
	Iter = dict_get(<<"iter">>, Slot),
	Salt = dict_get(<<"salt">>, Slot),
	EncMasterKey = dict_get(<<"enc-key">>, Slot),
	SlotKey = pbkdf2(Pwd, Salt, Iter, 16),
	Key = crypto:aes_cbc_128_decrypt(SlotKey, <<0:128>>, EncMasterKey),
	case Verify(Key) of
		true  -> Key;
		false -> open_slot(Pwd, Verify, Rest)
	end.


init_create_crypt(Pwd, #state{store=Store, sid=Doc} = S) ->
	try
		{ok, Rev, _PreRevs} = check(peerdrive_store:lookup(Store, Doc)),
		% use the broker to update to keep ref's intact
		{ok, Handle} = peerdrive_broker:update(Store, Doc, Rev,
			<<"org.peerdrive.crypt-store">>),
		try
			Key = crypto:strong_rand_bytes(16),
			SlotSalt = crypto:rand_bytes(32),
			SlotIter = crypto:rand_uniform(2048, 8192),
			SlotKey = pbkdf2(Pwd, SlotSalt, SlotIter, 16),
			SlotEncKey = crypto:aes_cbc_128_encrypt(SlotKey, <<0:128>>, Key),
			MkSalt = crypto:rand_bytes(32),
			MkIter = crypto:rand_uniform(2048, 8192),
			MkDigest = pbkdf2(Key, MkSalt, MkIter),
			EncSId = enc_xid(Key, Doc),

			Slot = gb_trees:from_orddict(orddict:from_list([ {<<"iter">>, SlotIter},
				{<<"salt">>, SlotSalt}, {<<"enc-key">>, SlotEncKey} ])),
			Spec = gb_trees:from_orddict(orddict:from_list([ {<<"version">>, 1},
				{<<"cipher">>, <<"aes">>}, {<<"hash">>, <<"sha1">>},
				{<<"mk-digest">>, MkDigest}, {<<"mk-salt">>, MkSalt},
				{<<"mk-iter">>, MkIter}, {<<"slots">>, [Slot]},
				{<<"root">>, {dlink, EncSId}} ])),

			check(peerdrive_broker:write(Handle, <<"ENCR">>, 0,
				peerdrive_struct:encode(Spec))),
			EncRootHandle = init_create_crypt_root(Store, EncSId, Key),
			try
				Annotation1 = gb_trees:empty(),
				Annotation2 = gb_trees:enter(<<"title">>,
					<<"New encrypted store">>, Annotation1), % TODO: get from unencrypted root
				Annotation3 = gb_trees:enter(<<"comment">>,
					<<"<<Initial store creation>>">>, Annotation2),
				RootMeta1 = gb_trees:empty(),
				RootMeta2 = gb_trees:enter(<<"org.peerdrive.annotation">>,
					Annotation3, RootMeta1),

				check(peerdrive_store:write(EncRootHandle, <<"PDSD">>, 0,
					peerdrive_struct:encode([]))),
				check(peerdrive_store:write(EncRootHandle, <<"META">>, 0,
					peerdrive_struct:encode(RootMeta2))),
				check(peerdrive_store:set_flags(EncRootHandle, ?REV_FLAG_STICKY)),

				check(peerdrive_store:commit(EncRootHandle)),
				check(peerdrive_broker:commit(Handle)),
				{ok, S#state{key=Key}}
			after
				peerdrive_store:close(EncRootHandle)
			end
		after
			peerdrive_broker:close(Handle)
		end
	catch
		throw:Error -> Error
	end.


init_create_crypt_root(Store, EncDId, Key) ->
	Rev = #revision{
		type    = <<"org.peerdrive.store">>,
		creator = <<"org.peerdrive.crypt-store">>
	},
	{ok, Handle} = peerdrive_crypt_store_io:start_link(Store, Key, undefined,
		EncDId, undefined, Rev, self()),
	Handle.


init_install_filter(#state{sid=SId, key=Key}) ->
	Fun = fun
		({vol_event, mod_doc, Store, Doc}) ->
			{vol_event, mod_doc, Store, dec_xid(Key, Doc)};
		({vol_event, add_rev, Store, Rev}) ->
			{vol_event, add_rev, Store, dec_xid(Key, Rev)};
		({vol_event, rem_rev, Store, Rev}) ->
			{vol_event, rem_rev, Store, dec_xid(Key, Rev)};
		({vol_event, add_doc, Store, Doc}) ->
			{vol_event, add_doc, Store, dec_xid(Key, Doc)};
		({vol_event, rem_doc, Store, Doc}) ->
			{vol_event, rem_doc, Store, dec_xid(Key, Doc)};
		(Default) ->
			Default
	end,
	ok = peerdrive_vol_monitor:add_filter(SId, Fun).


do_stat(Rev, #state{store=Store, key=Key}) ->
	case peerdrive_store:stat(Store, enc_xid(Key, Rev)) of
		{ok, EncStat} ->
			#rev_stat{
				flags     = EncFlags,
				parts     = EncParts,
				parents   = EncParents,
				mtime     = EncMtime,
				type      = EncType,
				creator   = EncCreator,
				comment   = EncComment,
				doc_links = EncDocLinks,
				rev_links = EncRevLinks
			} = EncStat,
			<<Flags:32>> = crypto:aes_ctr_decrypt(Key, ?CS_FLAGS_IVEC(Rev),
				<<EncFlags:32>>),
			<<Mtime:64>> = crypto:aes_ctr_decrypt(Key, ?CS_MTIME_IVEC(Rev),
				<<EncMtime:64>>),
			Stat = #rev_stat{
				flags     = Flags,
				parts     = [ {FCC, Size, dec_xid(Key, PId)} ||
					{FCC, Size, PId} <- EncParts ],
				parents   = [ dec_xid(Key, Parent) || Parent <- EncParents ],
				mtime     = Mtime,
				type      = crypto:aes_ctr_decrypt(Key, ?CS_TYPE_IVEC(Rev), EncType),
				creator   = crypto:aes_ctr_decrypt(Key, ?CS_CREATOR_IVEC(Rev),
					EncCreator),
				comment   = crypto:aes_ctr_decrypt(Key, ?CS_COMMENT_IVEC(Rev),
					EncComment),
				doc_links = [ dec_xid(Key, DId) || DId <- EncDocLinks ],
				rev_links = [ dec_xid(Key, RId) || RId <- EncDocLinks ]
			},
			{ok, Stat};

		{error, _} = Error ->
			Error
	end.


do_peek(RId, User, #state{store=Store, key=Key} = S) ->
	EncRId = enc_xid(Key, RId),
	case get_revision(RId, EncRId, S) of
		{ok, Rev} ->
			case peerdrive_store:peek(Store, EncRId) of
				{ok, Handle} ->
					peerdrive_crypt_store_io:start_link(Store, Key, Handle,
						undefined, undefined, Rev, User);
				{error, _} = Error ->
					Error
			end;

		{error, _} = Error ->
			Error
	end.


do_create(Type, Creator, User, #state{store=Store, key=Key}) ->
	DId = crypto:rand_bytes(16),
	EncDId = enc_xid(Key, DId),
	Rev = #revision{type=Type, creator=Creator},
	{ok, Handle} = peerdrive_crypt_store_io:start_link(Store, Key, undefined,
		EncDId, undefined, Rev, User),
	{ok, DId, Handle}.


do_fork(StartRId, Creator, User, #state{store=Store, key=Key}=S) ->
	EncStartRId = enc_xid(Key, StartRId),
	case get_revision(StartRId, EncStartRId, S) of
		{ok, Rev} ->
			case peerdrive_store:peek(Store, EncStartRId) of
				{ok, Handle} ->
					DId = crypto:rand_bytes(16),
					EncDId = enc_xid(Key, DId),
					NewRev = Rev#revision{
						parents = [StartRId],
						creator = Creator,
						comment = <<>>
					},
					{ok, MyHandle} = peerdrive_crypt_store_io:start_link(Store,
						Key, Handle, EncDId, undefined, NewRev, User),
					{ok, DId, MyHandle};

				{error, _} = Error ->
					Error
			end;

		{error, _} = Error ->
			Error
	end.


do_update(DId, StartRId, Creator, User, #state{store=Store, key=Key}=S) ->
	EncStartRId = enc_xid(Key, StartRId),
	case get_revision(StartRId, EncStartRId, S) of
		{ok, Rev} ->
			case peerdrive_store:peek(Store, EncStartRId) of
				{ok, Handle} ->
					NewCreator = case Creator of
						undefined -> Rev#revision.creator;
						_ -> Creator
					end,
					NewRev = Rev#revision{
						parents = [StartRId],
						creator = NewCreator,
						comment = <<>>
					},
					EncDId = enc_xid(Key, DId),
					{ok, _} = peerdrive_crypt_store_io:start_link(Store, Key,
						Handle, EncDId, undefined, NewRev, User);

				{error, _} = Error ->
					Error
			end;

		{error, _} = Error ->
			Error
	end.


do_resume(DId, PreRId, Creator, User, #state{store=Store, key=Key}=S) ->
	EncPreRId = enc_xid(Key, PreRId),
	case get_revision(PreRId, EncPreRId, S) of
		{ok, Rev} ->
			case peerdrive_store:peek(Store, EncPreRId) of
				{ok, Handle} ->
					NewCreator = case Creator of
						undefined -> Rev#revision.creator;
						_ -> Creator
					end,
					NewRev = Rev#revision{ creator=NewCreator },
					EncDId = enc_xid(Key, DId),
					{ok, _} = peerdrive_crypt_store_io:start_link(Store, Key,
						Handle, EncDId, EncPreRId, NewRev, User);

				{error, _} = Error ->
					Error
			end;

		{error, _} = Error ->
			Error
	end.


do_put_doc(Doc, Rev, User, #state{store=Store, key=Key}) ->
	EncDoc = enc_xid(Key, Doc),
	EncRev = enc_xid(Key, Rev),
	case peerdrive_store:put_doc(Store, EncDoc, EncRev) of
		ok ->
			ok;
		{ok, Handle} ->
			peerdrive_crypt_store_put:start_link(self(), Handle, User);
		{error, _} = Error ->
			Error
	end.


do_forward_doc(Doc, RevPath, OldPreRId, User, #state{store=Store, key=Key}) ->
	EncDoc = enc_xid(Key, Doc),
	EncRevPath = [ enc_xid(Key, Rev) || Rev <- RevPath ],
	EncOldPreRId = case OldPreRId of
		undefined -> undefined;
		_ -> enc_xid(Key, OldPreRId)
	end,
	case peerdrive_store:forward_doc_start(Store, EncDoc, EncRevPath, EncOldPreRId) of
		ok ->
			ok;
		{ok, Handle} ->
			peerdrive_crypt_store_fwd:start_link(self(), Handle, User);
		{error, _} = Error ->
			Error
	end.


do_put_rev(Rev, Revision, User, #state{store=Store, key=Key} = S) ->
	#revision{
		flags     = Flags,
		parts     = Parts,
		parents   = Parents,
		mtime     = Mtime,
		type      = TypeCode,
		creator   = CreatorCode,
		comment   = Comment,
		doc_links = DocLinks,
		rev_links = RevLinks
	} = Revision,
	<<EncFlags:32>> = crypto:aes_ctr_encrypt(Key, ?CS_FLAGS_IVEC(Rev), <<Flags:32>>),
	<<EncMtime:64>> = crypto:aes_ctr_encrypt(Key, ?CS_MTIME_IVEC(Rev), <<Mtime:64>>),
	EncRevision = #revision{
		flags     = EncFlags,
		parts     = [ {FCC, enc_xid(Key, PId)} || {FCC, PId} <- Parts ],
		parents   = [ enc_xid(Key, Parent) || Parent <- Parents ],
		mtime     = EncMtime,
		type      = crypto:aes_ctr_encrypt(Key, ?CS_TYPE_IVEC(Rev), TypeCode),
		creator   = crypto:aes_ctr_encrypt(Key, ?CS_CREATOR_IVEC(Rev), CreatorCode),
		comment   = crypto:aes_ctr_encrypt(Key, ?CS_COMMENT_IVEC(Rev), Comment),
		doc_links = [ enc_xid(Key, DId) || DId <- DocLinks ],
		rev_links = [ enc_xid(Key, RId) || RId <- DocLinks ]
	},
	case peerdrive_store:put_rev_start(Store, enc_xid(Key, Rev), EncRevision) of
		ok ->
			ok;
		{ok, Missing, Handle} ->
			MissingParts = [ M || M = {FCC, _PId} <- Parts,
				lists:member(FCC, Missing) ],
			{ok, Importer} = peerdrive_crypt_store_imp:start_link(self(), Key,
				Handle, MissingParts, User),
			{ok, Missing, Importer};
		{error, _} = Error ->
			Error
	end.


do_remember_rev(DId, NewPreRId, OldPreRId, User, #state{store=Store, key=Key}) ->
	EncDId = enc_xid(Key, DId),
	EncNew = enc_xid(Key, NewPreRId),
	EncOld = enc_xid(Key, OldPreRId),
	case peerdrive_store:remember_rev(Store, EncDId, EncNew, EncOld) of
		ok ->
			ok;
		{ok, Handle} ->
			peerdrive_crypt_store_rem:start_link(self(), Handle, User);
		{error, _} = Error ->
			Error
	end.


do_sync_get_changes(Peer, Anchor, Caller, #state{store=Store, key=Key} = S) ->
	case sync_lock(Peer, Caller, S) of
		{ok, S2} ->
			case peerdrive_store:sync_get_changes(Store, enc_xid(Key, Peer), Anchor) of
				{ok, EncBacklog} ->
					link(Caller),
					Backlog = [ {dec_xid(Key, DId), Seq} || {DId, Seq} <-
						EncBacklog ],
					{reply, {ok, Backlog}, S2};
				{error, _} = Error ->
					{reply, Error, S} % dump the lock
			end;

		error ->
			{reply, {error, ebusy}, S}
	end.


do_sync_get_anchor(FromSId, ToSId, #state{store=Store, key=Key}) ->
	peerdrive_store:sync_get_anchor(Store, enc_xid(Key, FromSId),
		enc_xid(Key, ToSId)).


do_sync_set_anchor(FromSId, ToSId, Seq, #state{store=Store, key=Key}) ->
	peerdrive_store:sync_set_anchor(Store, enc_xid(Key, FromSId),
		enc_xid(Key, ToSId), Seq).


do_sync_finish(Peer, Caller, S) ->
	#state{store=Store, synclocks=SLocks, key=Key} = S,
	case orddict:find(Peer, SLocks) of
		{ok, Caller} ->
			unlink(Caller),
			S2 = S#state{synclocks=orddict:erase(Peer, SLocks)},
			{reply, peerdrive_store:sync_finish(Store, enc_xid(Key, Peer)), S2};
		{ok, _Other} ->
			{reply, {error, eacces}, S};
		error ->
			{reply, {error, einval}, S}
	end.


sync_lock(Peer, Caller, #state{synclocks=SLocks} = S) ->
	case orddict:find(Peer, SLocks) of
		error ->
			{ok, S#state{synclocks=orddict:store(Peer, Caller, SLocks)}};
		{ok, Caller} ->
			{ok, S};
		{ok, _Other} ->
			error
	end.


sync_trap_exit(From, #state{synclocks=SLocks} = S) ->
	case lists:keytake(From, 2, SLocks) of
		false ->
			error;
		{value, {Peer, _From}, NewSLocks} ->
			#state{store=Store, key=Key} = S,
			peerdrive_store:sync_finish(Store, enc_xid(Key, Peer)),
			{ok, S#state{synclocks=NewSLocks}}
	end.


shutdown(Store) ->
    erlang:monitor(process, Store),
	exit(Store, shutdown),
	receive
		{'DOWN', _Ref, process, Store, shutdown} ->
			ok;
		{'DOWN', _Ref, process, Store, Reason} ->
			{error, Reason}
		after 29000 ->
			exit(Store, kill),
			receive
				{'DOWN', _Ref, process, Store, Reason} ->
					{error, Reason}
			end
	end.


check({error, _} = Error) ->
	throw(Error);
check(error) ->
	{error, eio};
check(Term) ->
	Term.


get_revision(RId, EncRId, #state{store=Store, key=Key}) ->
	case peerdrive_store:stat(Store, EncRId) of
		{ok, EncStat} ->
			#rev_stat{
				flags     = EncFlags,
				parts     = EncParts,
				parents   = EncParents,
				mtime     = EncMtime,
				type      = EncType,
				creator   = EncCreator,
				comment   = EncComment,
				doc_links = EncDocLinks,
				rev_links = EncRevLinks
			} = EncStat,
			<<Flags:32>> = crypto:aes_ctr_decrypt(Key, ?CS_FLAGS_IVEC(RId),
				<<EncFlags:32>>),
			<<Mtime:64>> = crypto:aes_ctr_decrypt(Key, ?CS_MTIME_IVEC(RId),
				<<EncMtime:64>>),
			Rev = #revision{
				flags     = Flags,
				parts     = [ {FCC, dec_xid(Key, PId)} ||
					{FCC, _Size, PId} <- EncParts ],
				parents   = [ dec_xid(Key, Parent) || Parent <- EncParents ],
				mtime     = Mtime,
				type      = crypto:aes_ctr_decrypt(Key, ?CS_TYPE_IVEC(RId), EncType),
				creator   = crypto:aes_ctr_decrypt(Key, ?CS_CREATOR_IVEC(RId),
					EncCreator),
				comment   = crypto:aes_ctr_decrypt(Key, ?CS_COMMENT_IVEC(RId),
					EncComment),
				doc_links = [ dec_xid(Key, DLId) || DLId <- EncDocLinks ],
				rev_links = [ dec_xid(Key, RLId) || RLId <- EncDocLinks ]
			},
			{ok, Rev};

		{error, _} = Error ->
			Error
	end.


dict_get(Key, Dict) ->
	case gb_trees:lookup(Key, Dict) of
		{value, Value} -> Value;
		none -> throw({error, eio})
	end.


% PBKDF2 with SHA1 HMAC and 20 bytes result max
pbkdf2(Pwd, Salt, Iterations) ->
	pbkdf2(Pwd, Salt, Iterations, 20).


pbkdf2(Pwd, Salt, Iterations, KeySize) when KeySize =< 20 ->
	binary_part(pbkdf2_block(Pwd, Salt, Iterations, 1), 0, KeySize);

pbkdf2(_, _, _, _) ->
	erlang:error(badarg).


pbkdf2_block(Pwd, Salt, Iterations, BlockNum) ->
    InitRound = crypto:sha_mac(Pwd, <<Salt/binary, BlockNum:32/integer>>),
	pbkdf2_block_loop(Pwd, Iterations-1, InitRound, InitRound).


pbkdf2_block_loop(_Pwd, 0, _Prev, Acc) ->
	Acc;

pbkdf2_block_loop(Pwd, Iterations, Prev, Acc) ->
    Next = crypto:sha_mac(Pwd, Prev),
	pbkdf2_block_loop(Pwd, Iterations-1, Next, crypto:exor(Next, Acc)).

