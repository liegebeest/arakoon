(*
Copyright (2010-2014) INCUBAID BVBA

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*)



open Lwt

let section = Logger.Section.main

let lwt_directory_list dn =
  Lwt.catch
    (fun () ->
      Lwt_unix.opendir dn >>= fun h ->
      let rec loop acc  =
        Lwt.catch
          (fun () ->
            Lwt_unix.readdir h >>= fun x ->
            match x with
              | "." | ".." -> loop acc
              | s' -> loop (s' :: acc)
          )
          (function
            | End_of_file -> Lwt.return (List.rev acc)
            | exn -> Lwt.fail exn
          )
      in
      Lwt.finalize
        (fun () -> loop [])
        (fun () -> Lwt_unix.closedir h)
    )
    (fun exn -> Logger.debug_f_ ~exn "lwt_directory_list %s" dn >>= fun () -> Lwt.fail exn)

let fsync_dir dir =
  let t0 = Unix.gettimeofday() in
  Lwt_unix.openfile dir [Unix.O_RDONLY] 0640 >>= fun dir_descr ->
  Lwt.finalize
    (fun () -> Lwt_unix.fsync dir_descr)
    (fun () -> Lwt_unix.close dir_descr
               >>= fun () ->
               let t1 = Unix.gettimeofday() in
               let d = t1 -. t0 in
               if d < 1.0
               then Lwt.return ()
               else Logger.warning_f_ "fsync_dir of %S took : %f" dir d
    )

let fsync_dir_of_file filename =
  fsync_dir (Filename.dirname filename)

let rename source target =
  Logger.info_f_ "rename %s -> %s" source target >>= fun () ->
  Lwt_unix.rename source target >>= fun () ->
  fsync_dir_of_file target

let mkdir name = Lwt_unix.mkdir name

let unlink name =
  Lwt.catch
    (fun () ->
     Logger.info_f_ "Unlinking %S" name >>= fun () ->
     Lwt_unix.unlink name)
    (function
      | Unix.Unix_error(Unix.ENOENT, _, _) ->
         Logger.info_f_ "Unlink of %S failed with ENOENT" name
      | e ->
         Lwt.fail e)

let rmdir name = Lwt_unix.rmdir name

let stat filename =
  Logger.debug_f_ "stat %S" filename >>= fun () ->
  Lwt_unix.stat filename

let exists filename =
  Lwt.catch
    (fun () -> stat filename >>= fun _ -> Lwt.return true)
    (function
      | Unix.Unix_error (Unix.ENOENT,_,_) -> Lwt.return false
      | e -> Lwt.fail e
    )

let copy_file source target ~overwrite = (* LOOKS LIKE Clone.copy_stream ... *)
  Logger.info_f_ "copy_file %S %S" source target >>= fun () ->
  let bs = Lwt_io.default_buffer_size () in
  let buffer = String.create bs in
  let copy_all ic oc =
    let rec loop () =
      Lwt_io.read_into ic buffer 0 bs >>= fun bytes_read ->
      if bytes_read > 0
      then
        begin
          Lwt_io.write oc buffer >>= fun () -> loop ()
        end
      else
        Lwt.return ()
    in
    loop () >>= fun () ->
    Logger.info_ "done: copy_file"
  in
  exists target >>= fun target_exists ->
  if target_exists && not overwrite
  then
    Logger.info_f_ "Not copying %s to %s because target already exists" source target
  else
    begin
      let tmp_file = target ^ ".tmp" in
      unlink tmp_file >>= fun () ->
      Lwt_io.with_file ~mode:Lwt_io.input source
        (fun ic ->
           Lwt_io.with_file ~flags:[Unix.O_WRONLY;Lwt_unix.O_EXCL;Lwt_unix.O_CREAT] ~mode:Lwt_io.output tmp_file
             (fun oc -> copy_all ic oc)
        ) >>= fun () ->
      rename tmp_file target
    end

let safe_rename src dest =
  Lwt_unix.stat src >>= fun ss ->
  Lwt_unix.stat dest >>= fun ds ->
  if ss.Lwt_unix.st_dev <> ds.Lwt_unix.st_dev
    then
      let msg = Printf.sprintf
        "File_system.safe_rename: src %S and dest %S on different filesystem"
        src dest
      in
      Lwt.fail (Failure msg)
    else
      (* Make sure this is the 'rename' from this module, not Lwt_unix.rename *)
      rename src dest
