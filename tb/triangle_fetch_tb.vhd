-- Integration test: real synchronous asset ROM plus controlled bad-ID injection.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity triangle_fetch_tb is
end entity;

architecture sim of triangle_fetch_tb is
  type ids_t is array (0 to 2) of unsigned(31 downto 0);
  type coords_t is array (0 to 2, 0 to 2) of signed(31 downto 0);
  type face_t is array (0 to 2) of natural;
  type faces_t is array (0 to 11) of face_t;
  -- Independent expectations from the supplied Ada cube, not from the ROM.
  constant FACES : faces_t := (
    (1,2,4), (3,4,2), (5,6,8), (7,8,6),
    (9,10,12), (11,12,10), (13,14,16), (15,16,14),
    (17,18,20), (19,20,18), (21,22,24), (23,24,22)
  );
  type xyz_t is array (0 to 2) of integer;
  type vertices_t is array (1 to 24) of xyz_t;
  constant VERTICES : vertices_t := (
    (-1,1,1), (1,1,1), (1,-1,1), (-1,-1,1),
    (-1,1,-1), (-1,1,1), (-1,-1,1), (-1,-1,-1),
    (-1,-1,1), (1,-1,1), (1,-1,-1), (-1,-1,-1),
    (1,1,1), (1,1,-1), (1,-1,-1), (1,-1,1),
    (-1,1,-1), (1,1,-1), (1,1,1), (-1,1,1),
    (-1,-1,-1), (1,-1,-1), (1,1,-1), (-1,1,-1)
  );

  signal clk : std_logic := '0';
  signal rstn, start_valid, ready : std_logic := '0';
  signal start_ready, valid, last, err : std_logic;
  signal addr : unsigned(9 downto 0);
  signal rom_data, read_data : std_logic_vector(31 downto 0);
  signal ids : ids_t;
  signal xyz : coords_t;
  signal transfers : natural := 0;
  signal inject, inject_q : std_logic := '0';
  signal bad_addr : unsigned(9 downto 0) := to_unsigned(144, 10);
  signal bad_value : std_logic_vector(31 downto 0) := (others => '0');
begin
  clk <= not clk after 5 ns;
  memory : entity work.asset_memory
    port map (clk => clk, addr => addr, data => rom_data);
  -- Align fault selection with the same edge on which the ROM samples addr.
  process(clk)
  begin
    if rising_edge(clk) then
      inject_q <= '0';
      if inject = '1' and addr = bad_addr then
        inject_q <= '1';
      end if;
    end if;
  end process;
  read_data <= bad_value when inject_q = '1' else rom_data;

  dut : entity work.triangle_fetch
    port map (
      clk_i => clk, rstn_i => rstn,
      frame_start_valid_i => start_valid, frame_start_ready_o => start_ready,
      mem_addr_o => addr, mem_data_i => read_data,
      triangle_valid_o => valid, triangle_ready_i => ready,
      triangle_last_o => last, err_o => err,
      vertex_a_id_o => ids(0), vertex_a_x_o => xyz(0,0),
      vertex_a_y_o => xyz(0,1), vertex_a_z_o => xyz(0,2),
      vertex_b_id_o => ids(1), vertex_b_x_o => xyz(1,0),
      vertex_b_y_o => xyz(1,1), vertex_b_z_o => xyz(1,2),
      vertex_c_id_o => ids(2), vertex_c_x_o => xyz(2,0),
      vertex_c_y_o => xyz(2,1), vertex_c_z_o => xyz(2,2)
    );

  scoreboard : process
    variable stalled : boolean := false;
    variable saved_ids : ids_t;
    variable saved_xyz : coords_t;
    variable saved_last : std_logic;
    variable face : natural;
  begin
    wait until rising_edge(clk);
    if rstn = '0' then
      stalled := false;
      transfers <= 0;
    else
      if stalled then
        assert valid = '1' and ids = saved_ids and xyz = saved_xyz and last = saved_last
          report "Triangle payload/valid changed under backpressure" severity failure;
      end if;
      if valid = '1' then
        assert err = '0' and start_ready = '0'
          report "A triangle must not be presented while idle or faulted" severity failure;
        face := transfers mod 12;
        for slot in 0 to 2 loop
          assert ids(slot) = to_unsigned(FACES(face)(slot), 32)
            report "Wrong vertex ID, face " & integer'image(face+1) &
                   ", slot " & integer'image(slot) severity failure;
          for axis in 0 to 2 loop
            assert xyz(slot,axis) =
                   to_signed(VERTICES(FACES(face)(slot))(axis) * 65536, 32)
              report "Wrong coordinate, face " & integer'image(face+1) &
                     ", slot " & integer'image(slot) &
                     ", axis " & integer'image(axis) severity failure;
          end loop;
        end loop;
        assert (last = '1') = (face = 11)
          report "Last marker does not match face 12" severity failure;
        if ready = '1' then
          transfers <= transfers + 1;
        end if;
      else
        assert last = '0' report "Last asserted outside a valid triangle" severity failure;
      end if;
      stalled := valid = '1' and ready = '0';
      if stalled then
        saved_ids := ids;
        saved_xyz := xyz;
        saved_last := last;
      end if;
    end if;
  end process;

  stimulus : process
    procedure tick is
    begin
      wait until rising_edge(clk);
      wait for 1 ns;
    end procedure;
    procedure reset_dut is
    begin
      rstn <= '0';
      start_valid <= '0';
      ready <= '0';
      inject <= '0';
      tick;
      assert start_ready = '1' and valid = '0' and last = '0' and err = '0'
        report "Reset did not restore idle outputs" severity failure;
      for slot in 0 to 2 loop
        assert ids(slot) = to_unsigned(0,32)
          report "Reset did not clear IDs" severity failure;
        for axis in 0 to 2 loop
          assert xyz(slot,axis) = to_signed(0,32)
            report "Reset did not clear coordinates" severity failure;
        end loop;
      end loop;
      rstn <= '1';
    end procedure;
    procedure start_frame is
    begin
      assert start_ready = '1' report "B is not ready for a frame" severity failure;
      start_valid <= '1';
      tick;
      start_valid <= '0';
      assert start_ready = '0' report "B did not accept frame start" severity failure;
    end procedure;
    procedure await_triangle is
    begin
      for cycle in 1 to 100 loop
        exit when valid = '1';
        tick;
      end loop;
      assert valid = '1' report "Timed out waiting for triangle" severity failure;
    end procedure;
    procedure run_frame(stall_cycles : natural) is
      variable initial_count : natural;
    begin
      initial_count := transfers;
      start_frame;
      for face in 1 to 12 loop
        ready <= '0';
        await_triangle;
        for cycle in 1 to stall_cycles loop
          tick;
        end loop;
        ready <= '1';
        tick;
        assert transfers = initial_count + face
          report "Triangle was duplicated or not accepted" severity failure;
        -- Keep ready asserted through the next fetch for the zero-stall case.
        if stall_cycles /= 0 then
          ready <= '0';
        end if;
      end loop;
      assert start_ready = '1' and valid = '0'
        report "B did not return idle after the final transfer" severity failure;
      for cycle in 1 to 4 loop tick; end loop;
      assert transfers = initial_count + 12
        report "Unexpected extra triangle after frame end" severity failure;
    end procedure;
    variable frozen_addr : unsigned(9 downto 0);
  begin
    reset_dut;
    -- Ready held high while fetching: earliest possible triangle acceptance.
    ready <= '1';
    start_frame;
    for cycle in 1 to 1000 loop
      exit when transfers = 12;
      tick;
    end loop;
    assert transfers = 12 and start_ready = '1'
      report "Unstalled frame did not complete exactly 12 transfers" severity failure;
    report "Unstalled cube frame passed";

    run_frame(4);
    assert transfers = 24 report "Second frame did not restart correctly" severity failure;
    report "Second frame with four-cycle triangle stalls passed";

    reset_dut;
    start_frame;
    for cycle in 1 to 5 loop tick; end loop;
    reset_dut;
    run_frame(1);
    report "Reset during fetch and restart passed";

    reset_dut;
    start_frame;
    await_triangle;
    tick;
    reset_dut;
    run_frame(0);
    report "Reset during a stalled triangle and restart passed";

    for test in 0 to 2 loop
      reset_dut;
      bad_addr <= to_unsigned(144 + test, 10);
      case test is
        when 0 => bad_value <= x"00000000";
        when 1 => bad_value <= x"00000019"; -- 25
        when others => bad_value <= x"FFFFFFFF";
      end case;
      inject <= '1';
      start_frame;
      for cycle in 1 to 100 loop
        exit when err = '1';
        tick;
      end loop;
      assert err = '1' and valid = '0' and start_ready = '0' and transfers = 0
        report "Malformed ID did not fault before presenting a triangle" severity failure;
      frozen_addr := addr;
      assert frozen_addr = bad_addr
        report "Invalid ID was used to issue a vertex address" severity failure;
      inject <= '0';
      start_valid <= '1';
      ready <= '1';
      for cycle in 1 to 10 loop
        tick;
        assert err = '1' and valid = '0' and start_ready = '0'
          and addr = frozen_addr and transfers = 0
          report "Fault did not remain latched and stop fetching" severity failure;
      end loop;
    end loop;
    report "Invalid IDs 0, 25 and 0xFFFFFFFF in all three slots passed";
    reset_dut;
    run_frame(2);
    report "Reset after fault and full-frame recovery passed";
    report "triangle_fetch_tb: ALL TESTS PASSED";
    finish(0);
    wait;
  end process;

  watchdog : process
  begin
    wait for 100 us;
    assert false report "triangle_fetch_tb: global timeout" severity failure;
    wait;
  end process;
end architecture sim;
