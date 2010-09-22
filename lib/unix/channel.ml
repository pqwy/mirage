(*
 * Copyright (c) 2010 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

(* TCP channel that uses the UNIX runtime to retrieve fds *)

open Mlnet.Types
open Lwt

type t = {
  fd: int;
  rx_cond: unit Lwt_condition.t;
  tx_cond: unit Lwt_condition.t;
}

exception Not_implemented of string
exception Listen_error of string
exception Accept_error of string
exception Connect_error of string

external unix_close: int -> unit = "caml_socket_close"
external unix_tcp_connect: int32 -> int -> int resp = "caml_tcp_connect"
external unix_socket_read: int -> string -> int -> int -> int resp = "caml_socket_read"
external unix_socket_write: int -> string -> int -> int -> int resp = "caml_socket_write"
external unix_tcp_connect_result: int -> unit resp = "caml_tcp_connect_result"
external unix_tcp_listen: int32 -> int -> int resp = "caml_tcp_listen"
external unix_tcp_accept: int -> int resp = "caml_tcp_accept"

let t_of_fd fd = 
  let rx_cond = Lwt_condition.create () in
  let tx_cond = Lwt_condition.create () in
  { fd; rx_cond; tx_cond }

let t_wait_rx t = Activations.wait_rx t.fd t.rx_cond
let t_wait_tx t = Activations.wait_tx t.fd t.tx_cond

let close t =
  unix_close t.fd

let close_on_exit t th =
  try_lwt 
    th >> 
    return (close t)
  with exn -> 
    close t;
    fail exn

let connect = function
  | TCP (addr, port) -> begin
    match unix_tcp_connect (ipv4_addr_to_uint32 addr) port with
    | OK fd ->
      (* Wait for the connect to complete *)
      let t = t_of_fd fd in
      let rec loop () =
        t_wait_tx t >>
        match unix_tcp_connect_result t.fd with
        | OK () -> return (OK t)
        | Err s -> fail (Connect_error s)
        | Retry -> loop () in
      loop ()
    | Err s -> return (Err s)
    | Retry -> assert false (* initial connect cannot request a retry *)
  end
  | UDP _ -> fail (Not_implemented "UDP")

let listen fn = function
  | TCP (addr, port) -> begin
    match unix_tcp_listen (ipv4_addr_to_uint32 addr) port with
    | OK fd ->
      let lt = t_of_fd fd in
      (* Listen in a loop for new connections *)
      let abort_waiter, abort_wakener = Lwt.task () in
      let rec loop () =
        t_wait_rx lt >>
        (match unix_tcp_accept fd with
        | OK afd ->
            let t = t_of_fd afd in
            join [ loop (); close_on_exit t (fn t) ]
        | Retry -> 
            loop () 
        | Err err -> 
            Lwt.wakeup_exn abort_wakener (Accept_error err);
            loop ())
      in
      let x = loop () in
      Lwt.on_cancel x (fun () -> close lt);
      Lwt.pick [ abort_waiter; x]
    | Err s -> fail (Listen_error s)
    | Retry -> assert false (* Listen never blocks *)
  end
  | UDP _ -> fail (Not_implemented "UDP")

let rec read t buf off len =
  match unix_socket_read t.fd buf off len with
  | Retry ->
    (* Would block, so register an activation and wait *)
    t_wait_rx t >>
    read t buf off len
  | OK _ | Err _ as r -> 
    (* Return anything else normally *)
    return r
        
let rec write t buf off len =
  match unix_socket_write t.fd buf off len with 
  | Retry ->
    (* Would block, so register an activation and wait *)
    t_wait_tx t >>
    write t buf off len
  | OK _ | Err _ as r ->
    (* Return anything else normally *)
    return r

