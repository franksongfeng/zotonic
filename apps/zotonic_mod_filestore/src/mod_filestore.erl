%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2014-2020 Marc Worrell
%% @doc Module managing the storage of files on remote servers.

%% Copyright 2014-2020 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(mod_filestore).

-author("Marc Worrell <marc@worrell.nl>").
-mod_title("File Storage").
-mod_description("Store files on cloud storage services like Amazon S3 and Google Cloud Storage").
-mod_prio(500).
-mod_schema(1).
-mod_provides([filestore]).
-mod_depends([cron]).

-behaviour(supervisor).

-include_lib("zotonic_core/include/zotonic.hrl").
-include_lib("zotonic_core/include/zotonic_file.hrl").
-include_lib("zotonic_mod_admin/include/admin_menu.hrl").

-define(BATCH_SIZE, 200).

-export([
    observe_filestore/2,
    observe_media_update_done/2,
    observe_filestore_credentials_lookup/2,
    observe_filestore_credentials_revlookup/2,
    observe_admin_menu/3,

    pid_observe_tick_1m/3,

    queue_all/1,
    queue_all_stop/1,

    task_queue_all/3,

    lookup/2,

    delete_ready/5,
    download_stream/5,
    manage_schema/2
    ]).

-export([
    start_link/1,
    init/1
    ]).


observe_media_update_done(#media_update_done{action=insert, post_props=Props}, Context) ->
    queue_medium(Props, Context);
observe_media_update_done(#media_update_done{}, _Context) ->
    ok.

observe_filestore(#filestore{action=lookup, path=Path}, Context) ->
    lookup(Path, Context);
observe_filestore(#filestore{action=upload, path=Path, mime=undefined} = Upload, Context) ->
    Mime = z_media_identify:guess_mime(Path),
    observe_filestore(Upload#filestore{mime=Mime}, Context);
observe_filestore(#filestore{action=upload, path=Path, mime=Mime}, Context) ->
    MediaProps = #{
        <<"mime">> => Mime
    },
    maybe_queue_file(<<>>, Path, true, MediaProps, Context),
    ok;
observe_filestore(#filestore{action=delete, path=Path}, Context) ->
    Count = m_filestore:mark_deleted(Path, Context),
    lager:debug("filestore: marked ~p entries as deleted for ~p", [Count, Path]),
    ok.

observe_filestore_credentials_lookup(#filestore_credentials_lookup{path=Path}, Context) ->
    S3Key = m_config:get_value(?MODULE, s3key, Context),
    S3Secret = m_config:get_value(?MODULE, s3secret, Context),
    S3Url = m_config:get_value(?MODULE, s3url, Context),
    case is_defined(S3Key) andalso is_defined(S3Secret) andalso is_defined(S3Url) of
        true ->
            Url = make_url(S3Url, Path),
            {ok, #filestore_credentials{
                    service = <<"s3">>,
                    location = Url,
                    credentials = {S3Key,S3Secret}
            }};
        false ->
            undefined
    end.

observe_filestore_credentials_revlookup(#filestore_credentials_revlookup{service= <<"s3">>, location=Location}, Context) ->
    S3Key = m_config:get_value(?MODULE, s3key, Context),
    S3Secret = m_config:get_value(?MODULE, s3secret, Context),
    case is_defined(S3Key) andalso is_defined(S3Secret) of
        true ->
            {ok, #filestore_credentials{
                    service = <<"s3">>,
                    location = Location,
                    credentials = {S3Key,S3Secret}
            }};
        false ->
            undefined
    end.

observe_admin_menu(#admin_menu{}, Acc, Context) ->
    [
     #menu_item{id=admin_filestore,
                parent=admin_system,
                label=?__("Cloud File Store", Context),
                url={admin_filestore},
                visiblecheck={acl, use, mod_config}}

     |Acc].



make_url(S3Url, <<$/, _/binary>> = Path) ->
    <<S3Url/binary, Path/binary>>;
make_url(S3Url, Path) ->
    <<S3Url/binary, $/, Path/binary>>.

is_defined(undefined) -> false;
is_defined(<<>>) -> false;
is_defined(_) -> true.

pid_observe_tick_1m(Pid, tick_1m, Context) ->
    case z_convert:to_bool(m_config:get_value(?MODULE, is_upload_enabled, Context)) of
        true ->
            start_uploaders(Pid, m_filestore:fetch_queue(Context), Context);
        false ->
            nop
    end,
    start_downloaders(m_filestore:fetch_move_to_local(Context), Context),
    case m_config:get_value(?MODULE, delete_interval, <<"0">>, Context) of
        false ->
            nop;
        <<"false">> ->
            nop;
        undefined ->
            %% For BC, when the config option was not set.
            start_deleters(m_filestore:fetch_deleted(<<"0">>, Context), Context);
        Interval ->
            start_deleters(m_filestore:fetch_deleted(Interval, Context), Context)
    end.


manage_schema(What, Context) ->
    m_filestore:install(What, Context).

lookup(Path, Context) ->
    case m_filestore:lookup(Path, Context) of
        undefined ->
            undefined;
        #{ location := Location } = StoreEntry ->
            case filezcache:locate_monitor(Location) of
                {ok, {file, _Size, Filename}} ->
                    {ok, {filename, Filename, StoreEntry}};
                {ok, {pid, Pid}} ->
                    {ok, {filezcache, Pid, StoreEntry}};
                {error, enoent} ->
                    load_cache(StoreEntry, Context)
            end
    end.

load_cache(#{
            service := Service,
            location := Location,
            size := Size,
            id := Id
        } = StoreEntry, Context) ->
    case z_notifier:first(
        #filestore_credentials_revlookup{ service=Service, location=Location },
        Context)
    of
        {ok, #filestore_credentials{ service= <<"s3">>, location=Location1, credentials=Cred }} ->
            lager:debug("File store cache load of ~p", [Location]),
            Ctx = z_context:prune_for_async(Context),
            StreamFun = fun(CachePid) ->
                s3filez:stream(
                    Cred,
                    Location1,
                    fun
                        ({error, FinalError}) when FinalError =:= enoent; FinalError =:= forbidden ->
                            lager:error("File store remote file is ~p ~p", [FinalError, Location]),
                            ok = m_filestore:mark_error(Id, FinalError, Ctx),
                            exit(normal);
                        ({error, _} = Error) ->
                            % Abnormal exit when receiving an error.
                            % This takes down the cache entry.
                            lager:error("File store error ~p on cache load of ~p", [Error, Location]),
                            exit(Error);
                        (T) when is_tuple(T) ->
                            nop;
                        (B) when is_binary(B) ->
                            filezcache:append_stream(CachePid, B);
                         (eof) ->
                            filezcache:finish_stream(CachePid)
                    end)
            end,
            case filezcache:insert_stream(Location, Size, StreamFun, [monitor]) of
                {ok, Pid} ->
                    {ok, {filezcache, Pid, StoreEntry}};
                {error, {already_started, Pid}} ->
                    {ok, {filezcache, Pid, StoreEntry}}
            end;
        undefined ->
            undefined
    end.

queue_all(Context) ->
    Max = z_db:q1("select count(*) from medium", Context),
    z_pivot_rsc:insert_task(?MODULE, task_queue_all, filestore_queue_all, [0, Max], Context).

queue_all_stop(Context) ->
    z_pivot_rsc:delete_task(?MODULE, task_queue_all, filestore_queue_all, Context).

task_queue_all(Offset, Max, Context) when Offset =< Max ->
    case z_db:qmap_props("
        select *
        from medium
        order by id asc
        limit $1
        offset $2",
        [ ?BATCH_SIZE, Offset ],
        [ {keys, binary} ],
        Context)
    of
        {ok, Media} ->
            lager:info("Ensuring ~p files are queued for remote upload.", [length(Media)]),
            lists:foreach(fun(M) ->
                            queue_medium(M, Context)
                          end,
                          Media),
            {delay, 0, [Offset+?BATCH_SIZE, Max]};
        {error, _} = Error ->
            lager:error("Error ~p when queueing files for remote upload.", [Error]),
            {delay, 60, [Offset, Max]}
    end;
task_queue_all(_Offset, _Max, _Context) ->
    ok.


%% @doc Queue the medium entry and its preview for upload.
-spec queue_medium( z_media_identify:media_info(), z:context() ) -> ok | nop.
queue_medium(Medium, Context) ->
    Filename = maps:get(<<"filename">>, Medium, undefined),
    IsDeletable = maps:get(<<"is_deletable_file">>, Medium, undefined),
    Preview = maps:get(<<"preview_filename">>, Medium, undefined),
    PreviewDeletable = maps:get(<<"is_deletable_preview">>, Medium, undefined),
    Medium1 = maps:remove(<<"exif">>, Medium),
    % Queue the main medium record for upload.
    maybe_queue_file(<<"archive/">>, Filename, IsDeletable, Medium1, Context),
    % Queue the (optional) preview file.
    MediumPreview = #{
        <<"id">> => maps:get(<<"id">>, Medium, undefined)
    },
    maybe_queue_file(<<"archive/">>, Preview, PreviewDeletable, MediumPreview, Context).


maybe_queue_file(_Prefix, undefined, _IsDeletable, _MediaInfo, _Context) ->
    nop;
maybe_queue_file(_Prefix, <<>>, _IsDeletable, _MediaInfo, _Context) ->
    nop;
maybe_queue_file(_Prefix, _Path, false, _MediaInfo, _Context) ->
    nop;
maybe_queue_file(Prefix, Filename, true, MediaInfo, Context) ->
    FilenameBin = z_convert:to_binary(Filename),
    case m_filestore:queue(<<Prefix/binary, FilenameBin/binary>>, MediaInfo, Context) of
        ok -> ok;
        {error, duplicate} -> ok
    end.



%%% ------------------------------------------------------------------------------------
%%% Supervisor callbacks
%%% ------------------------------------------------------------------------------------

start_link(Args) ->
    supervisor:start_link(?MODULE, Args).

init(_Args) ->
    {ok,{{simple_one_for_one, 20, 10},
         [
          {undefined, {filestore_uploader, start_link, []},
           transient, brutal_kill, worker, [filestore_uploader]}
         ]}}.


%%% ------------------------------------------------------------------------------------
%%% Support routines
%%% ------------------------------------------------------------------------------------

-spec start_uploaders(pid(), [ m_filestore:queue_entry() ], z:context()) -> ok.
start_uploaders(Pid, Rs, Context) ->
    lists:foreach(
        fun(QueueEntry) ->
            start_uploader(Pid, QueueEntry, Context)
        end,
        Rs).

start_uploader(Pid, #{ id := Id, path := Path, props := MediumInfo }, Context) ->
    supervisor:start_child(Pid, [Id, Path, MediumInfo, Context]).

-spec start_deleters( [ m_filestore:filestore_entry() ], z:context() ) -> ok.
start_deleters(Rs, Context) ->
    lists:foreach(
        fun(FilestoreEntry) ->
            start_deleter(FilestoreEntry, Context)
        end,
        Rs).

start_deleter(#{
            id := Id,
            path := Path,
            service := Service,
            location := Location
        } = FilestoreEntry, Context) ->
    case z_notifier:first(#filestore_credentials_revlookup{service=Service, location=Location}, Context) of
        {ok, #filestore_credentials{service= <<"s3">>, location=Location1, credentials=Cred}} ->
            lager:debug("Queue delete for ~p", [Location1]),
            ContextAsync = z_context:prune_for_async(Context),
            _ = s3filez:queue_delete_id({?MODULE, delete, Id}, Cred, Location1, {?MODULE, delete_ready, [Id, Path, ContextAsync]});
        undefined ->
            lager:debug("No credentials for ~p", [FilestoreEntry])
    end.

delete_ready(Id, Path, Context, _Ref, ok) ->
    lager:debug("Delete remote file for ~p", [Path]),
    m_filestore:purge_deleted(Id, Context);
delete_ready(Id, Path, Context, _Ref, {error, enoent}) ->
    lager:debug("Delete remote file for ~p was not found", [Path]),
    m_filestore:purge_deleted(Id, Context);
delete_ready(Id, Path, Context, _Ref, {error, forbidden}) ->
    lager:debug("Delete remote file for ~p was forbidden", [Path]),
    m_filestore:purge_deleted(Id, Context);
delete_ready(_Id, Path, _Context, _Ref, {error, _} = Error) ->
    lager:error("Could not delete remote file. Path ~p error ~p", [Path, Error]).


-spec start_downloaders( [ m_filestore:filestore_entry() ], z:context() ) -> ok.
start_downloaders(Rs, Context) ->
    lists:foreach(
        fun(FilestoreEntry) ->
            start_downloader(FilestoreEntry, Context)
        end,
        Rs).

start_downloader(#{
            id := Id,
            path := Path,
            service := Service,
            location := Location
        } = FilestoreEntry, Context) ->
    case z_notifier:first(#filestore_credentials_revlookup{service=Service, location=Location}, Context) of
        {ok, #filestore_credentials{service= <<"s3">>, location=Location1, credentials=Cred}} ->
            LocalPath = z_path:files_subdir(Path, Context),
            ok = z_filelib:ensure_dir(LocalPath),
            lager:debug("Queue move to local for ~p", [Location1]),
            ContextAsync = z_context:prune_for_async(Context),
            _ = s3filez:queue_stream_id({?MODULE, stream, Id}, Cred, Location1, {?MODULE, download_stream, [Id, Path, LocalPath, ContextAsync]});
        undefined ->
            lager:debug("No credentials for ~p", [FilestoreEntry])
    end.

download_stream(_Id, _Path, LocalPath, _Context, {content_type, _}) ->
    lager:debug("Download remote file ~p started", [LocalPath]),
    file:delete(temp_path(LocalPath));
download_stream(_Id, _Path, LocalPath, _Context, Data) when is_binary(Data) ->
    file:write_file(temp_path(LocalPath), Data, [append,raw,binary]);
download_stream(Id, Path, LocalPath, Context, eof) ->
    lager:debug("Download remote file ~p ready", [LocalPath]),
    ok = file:rename(temp_path(LocalPath), LocalPath),
    m_filestore:purge_move_to_local(Id, Context),
    filezcache:delete({z_context:site(Context), Path}),
    filestore_uploader:stale_file_entry(Path, Context);
download_stream(Id, _Path, LocalPath, Context, {error, _} = Error) ->
    lager:debug("Download error ~p file ~p", [Error, LocalPath]),
    file:delete(temp_path(LocalPath)),
    m_filestore:unmark_move_to_local(Id, Context);
download_stream(_Id, _Path, _LocalPath, _Context, _Other) ->
    ok.

temp_path(F) when is_list(F) ->
    F ++ ".downloading";
temp_path(F) when is_binary(F) ->
    <<F/binary, ".downloading">>.
