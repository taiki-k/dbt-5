/*
 * 2006 Rilson Nascimento
 *
 * Trade Order transaction
 * ------------------------
 * The Trade Order transaction is designed to emulate the process of ordering the
 * trade, buy or sell, of a security by a Customer, Broker, or authorized third-party.
 *
 * Based on TPC-E Standard Specification Draft Revision 0.32.2c Clause 3.3.5.
 */

/*
 * Frame 1
 * Responsible for retrieving information about the customer, customer account, and its broker
 */

CREATE OR REPLACE FUNCTION TradeOrderFrame1 (IN acct_id IDENT_T) RETURNS record AS $$
DECLARE
	rs RECORD;
BEGIN
	SELECT  CA_B_ID,
		CA_C_ID,
		CA_NAME,
		CA_TAX_ST,
		C_L_NAME,
		C_F_NAME,
		C_TAX_ID,
		C_TIER,
		B_NAME
	INTO	rs
	FROM    CUSTOMER_ACCOUNT,
		CUSTOMER,
		BROKER
	WHERE   CA_ID   = acct_id AND
		CA_C_ID = C_ID AND
		CA_B_ID = B_ID;

	RETURN rs;
END;
$$ LANGUAGE 'plpgsql';


/*
 * Frame 2
 * Responsible for validating the executor's permission to order trades for the
 * specified customer account
 */

CREATE OR REPLACE FUNCTION TradeOrderFrame2(
				IN acct_id 	IDENT_T, 
				IN exec_f_name	varchar,
				IN exec_l_name	varchar,
				IN exec_tax_id	varchar) RETURNS smallint AS $$
DECLARE
	permission_cnt integer;
	bad_permission smallint;
BEGIN
	SELECT	COUNT(*)
	INTO	permission_cnt
	FROM	ACCOUNT_PERMISSION
	WHERE	AP_CA_ID = acct_id AND
		AP_F_NAME = exec_f_name AND
		AP_L_NAME = exec_l_name AND
		AP_TAX_ID = exec_tax_id;

	IF permission_cnt = 0 THEN
		bad_permission = 1;
	ELSE
		bad_permission = 0;
	END IF;

	RETURN	bad_permission;
END;
$$ LANGUAGE 'plpgsql';


/*
 * Frame 3
 * Responsible for estimating the overall impact of executing the requested trade
 */

CREATE OR REPLACE FUNCTION TradeOrderFrame3(
				IN acct_id		IDENT_T,
				IN cust_id		IDENT_T,
				IN cust_tier		smallint,
				IN is_lifo		bool,
				IN issue		char(6),
				IN st_pending_id	char(4),
				IN st_submitted_id	char(4),
				IN tax_status		smallint,
				IN trade_qty		S_QTY_T,
				IN trade_type_id	char(3),
				IN type_is_margin	smallint,
				IN co_name		varchar,
				IN requested_price	S_PRICE_T,
				IN symbol		varchar) RETURNS record AS $$
DECLARE
	-- output parameters
	comp_name	varchar;
	requested_price	S_PRICE_T;	
	symb_name	varchar;
	buy_value	BALANCE_T;
	charge_amount	VALUE_T;
	comm_rate	S_PRICE_T;
	cust_assets	BALANCE_T;
	market_price	S_PRICE_T;
	sec_name	varchar;
	sell_value	BALANCE_T;
	status_id	char(4);
	tax_amount	VALUE_T;
	type_is_market	boolean;
	type_is_sell	boolean;

	-- variables
	comp_id		IDENT_T;
	exch_id		char(6);
	tax_rates	S_PRICE_T;
	acct_bal	BALANCE_T;
	hold_assets	S_PRICE_T;
	rs		RECORD;

	-- Local frame variables used when estimating impact of this trade on
	-- any current holdings of the same security.
	hold_price	S_PRICE_T;
	hold_qty	S_QTY_T;
	needed_qty	S_QTY_T;
	holdsum_qty	S_QTY_T;

	-- cursor
	hold_list	refcursor;
BEGIN
	-- Get information on the security
	IF symbol = '' THEN
		SELECT	CO_ID
		INTO	comp_id
		FROM	COMPANY
		WHERE	CO_NAME = co_name;

		SELECT	S_EX_ID,
			S_NAME,
			S_SYMB
		INTO	exch_id,
			symb_name
		FROM	SECURITY
		WHERE	S_CO_ID = comp_id AND
			S_ISSUE = issue;
	ELSE
		SELECT	S_CO_ID,
			S_EX_ID,
			S_NAME
		INTO	comp_id,
			exch_id,
			symb_name
		FROM	SECURITY
		WHERE	S_SYMB = symbol;

		SELECT	CO_NAME
		INTO	comp_name
		FROM	COMPANY
		WHERE	CO_ID = comp_id;
	END IF;

	-- Get current pricing information for the security
	SELECT 	LT_PRICE
	INTO	market_price
	FROM	LAST_TRADE
	WHERE	LT_S_SYMB = symbol;
	
	-- Set trade characteristics based on the type of trade.
	SELECT	TT_IS_MKRT,
		TT_IS_SELL
	INTO	type_is_market,
		type_is_sell
	FROM	TRADE_TYPE
	WHERE	TT_ID = trade_type_id;

	-- If this is a limit-order, then the requested_price was passed in to us, but
	-- if this this a market-order, then we need to set the requested_price to the
	-- current market price.
	IF type_is_market THEN
		requested_price = market_price;
	END IF;

	-- Initialize variables
	buy_value = 0.0;
	sell_value = 0.0;
	needed_qty = trade_qty;

	SELECT	HS_QTY
	INTO	holdsum_qty
	FROM	HOLDING_SUMMARY
	WHERE	HS_CA_ID = acct_id AND
		HS_S_SYMB = symbol;

	IF type_is_sell THEN
	-- This is a sell transaction, so estimate the impact to any currently held
	-- long postions in the security.
	--
		IF holdsum_qty > 0 THEN
			IF is_lifo THEN
				-- Estimates will be based on closing most recently acquired holdings
				-- Could return 0, 1 or many rows
				OPEN	hold_list FOR
				SELECT	H_QTY,
					H_PRICE
				FROM	HOLDING
				WHERE	H_CA_ID = acct_id AND
					H_S_SYMB = symbol
				ORDER BY H_DTS DESC;
			ELSE
				-- Estimates will be based on closing oldest holdings
				-- Could return 0, 1 or many rows
				OPEN	hold_list FOR
				SELECT	H_QTY,
					H_PRICE
				FROM	HOLDING
				WHERE	H_CA_ID = acct_id AND
					H_S_SYMB = symbol
				ORDER BY H_DTS ASC;
			END IF;

			-- Estimate, based on the requested price, any profit that may be realized
			-- by selling current holdings for this security. The customer may have
			-- multiple holdings for this security (representing different purchases of
			-- this security at different times and therefore, most likely, different prices).

			WHILE needed_qty = 0 LOOP
				FETCH	hold_list
				INTO	hold_qty,
					hold_price;
				EXIT WHEN NOT FOUND;

				IF hold_qty > needed_qty THEN
					-- Only a portion of this holding would be sold as a result of the
					-- trade.
					buy_value = buy_value + (needed_qty * hold_price);
					sell_value = sell_value + (needed_qty * requested_price);
					needed_qty = 0;
				ELSE
					-- All of this holding would be sold as a result of this trade.
					buy_value = buy_value + (hold_qty * hold_price);
					sell_value = sell_value + (hold_qty * requested_price);
					needed_qty = needed_qty - hold_qty;
				END IF;
			END LOOP;

			CLOSE hold_list;
		END IF;

		-- NOTE: If needed_qty is still greater than 0 at this point, then the
		-- customer would be liquidating all current holdings for this security, and
		-- then short-selling this remaining balance for the transaction.
	ELSE
		-- This is a buy transaction, so estimate the impact to any currently held
		-- short positions in the security. These are represented as negative H_QTY
		-- holdings. Short postions will be covered before opening a long postion in
		-- this security.

		IF holdsum_qty < 0 THEN  -- Existing short position to buy

			IF is_lifo THEN
				-- Estimates will be based on closing most recently acquired holdings
				-- Could return 0, 1 or many rows

				OPEN 	hold_list FOR
				SELECT	H_QTY,
					H_PRICE
				FROM	HOLDING
				WHERE	H_CA_ID = acct_id AND
					H_S_SYMB = symbol
				ORDER BY H_DTS DESC;
			ELSE
				-- Estimates will be based on closing oldest holdings
				-- Could return 0, 1 or many rows

				OPEN	hold_list FOR
				SELECT	H_QTY,
					H_PRICE
				FROM	HOLDING
				WHERE	H_CA_ID = acct_id AND
					H_S_SYMB = symbol
				ORDER BY H_DTS ASC;
			END IF;

			-- Estimate, based on the requested price, any profit that may be realized
			-- by covering short postions currently held for this security. The customer
			-- may have multiple holdings for this security (representing different
			-- purchases of this security at different times and therefore, most
			-- likely, different prices).
			
			WHILE needed_qty = 0 LOOP
				FETCH	hold_list
				INTO	hold_qty,
					hold_price;
				EXIT WHEN NOT FOUND;

				IF (hold_qty + needed_qty < 0) THEN
					-- Only a portion of this holding would be covered (bought back) as
					-- a result of this trade.
					sell_value = sell_value + (needed_qty * hold_price);
					buy_value = buy_value + (needed_qty * requested_price);
					needed_qty = 0;
				ELSE
					-- All of this holding would be covered (bought back) as
					-- a result of this trade.
					-- NOTE: Local variable hold_qty is made positive for easy
					-- calculations
					hold_qty = -hold_qty;
					sell_value = sell_value + (hold_qty * hold_price);
					buy_value = buy_value + (hold_qty * requested_price);
					needed_qty = needed_qty - hold_qty;
				END IF;
			END LOOP;

			CLOSE hold_list;
		END IF;

		-- NOTE: If needed_qty is still greater than 0 at this point, then the
		-- customer would cover all current short positions for this security,
		-- (if any) and then open a new long position for the remaining balance
		-- of this transaction.
	END IF;

	-- Estimate any capital gains tax that would be incurred as a result of this
	-- transaction.

	tax_amount = 0.0;

	IF (sell_value > buy_value) AND ((tax_status = 1) OR (tax_status = 2)) THEN
		--
		-- Customer’s can be (are) subject to more than one tax rate.
		-- For example, a state tax rate and a federal tax rate. Therefore,
		-- get all tax rates the customer is subject to, and estimate overall
		-- amount of tax that would result from this order.
		--
		SELECT	sum(TX_RATE)
		INTO	tax_rates
		FROM	TAXRATE
		WHERE	TX_ID IN (
				SELECT	CX_TX_ID
				FROM	CUSTOMER_TAXRATE
				WHERE	CX_C_ID = cust_id);

		tax_amount = (sell_value - buy_value) * tax_rates;
	END IF;

	-- Get administrative fees (e.g. trading charge, commision rate)
	SELECT	CR_RATE
	INTO	comm_rate
	FROM	COMMISSION_RATE
	WHERE	CR_C_TIER = cust_tier AND
		CR_TT_ID = trade_type_id AND
		CR_EX_ID = exch_id AND
		CR_FROM_QTY <= trade_qty AND
		CR_TO_QTY >= trade_qty;

	SELECT	CH_CHRG
	INTO	charge_amount
	FROM	CHARGE
	WHERE	CH_C_TIER = cust_tier AND
		CH_TT_ID = trade_type_id;

	-- Compute assets on margin trades
	cust_assets = 0.0;

	IF type_is_margin THEN
		SELECT	CA_BAL
		INTO	acct_bal
		FROM	CUSTOMER_ACCOUNT
		WHERE	CA_ID = acct_id;

		-- Should return 0 or 1 row
		SELECT	sum(HS_QTY * LT_PRICE)
		INTO	hold_assets
		FROM	HOLDING_SUMMARY,
			LAST_TRADE
		WHERE	HS_CA_ID = acct_id AND
			LT_S_SYMB = HS_S_SYMB;

		IF hold_assets is NULL THEN /* account currently has no holdings */
			cust_assets = acct_bal;
		END IF;
	ELSE
		cust_assets = hold_assets + acct_bal;
	END IF;

	-- Set the status for this trade
	IF type_is_market THEN
		status_id = st_submitted_id;
	ELSE
		status_id = st_pending_id;
	END IF;

	-- Return output parameters
	SELECT	comp_name,
		requested_price,
		symb_name,
		buy_value,
		charge_amount,
		comm_rate,
		cust_assets,
		market_price,
		sec_name,
		sell_value,
		status_id,
		tax_amount,
		type_is_market,
		type_is_sell
	INTO	rs;

	RETURN	rs;
END;
$$ LANGUAGE 'plpgsql';


/*
 * Frame 4
 * Responsible for for creating an audit trail record of the order 
 * and assigning a unique trade ID to it.
 */

CREATE OR REPLACE FUNCTION TradeOrderFrame4(
				IN acct_id            IDENT_T,
				IN charge_amount      VALUE_T,
				IN comm_amount        VALUE_T,
				IN exec_name          char(64),
				IN is_cash            bool,
				IN is_lifo            bool,
				IN requested_price    S_PRICE_T,
				IN status_id          char(4),
				IN symbol             varchar(15),
				IN trade_qty          S_QTY_T,
				IN trade_type_id      char(3),
				IN type_is_market     smallint) RETURNS TRADE_T AS $$
DECLARE
	-- variables
	now_dts		timestamp;
	trade_id	TRADE_T;
BEGIN
	-- Get the timestamp
	SELECT	NOW()
	INTO	now_dts;

	-- Record trade information in TRADE table.
	INSERT INTO TRADE (
			T_ID, T_DTS, T_ST_ID, T_TT_ID, T_IS_CASH,
			T_S_SYMB, T_QTY, T_BID_PRICE, T_CA_ID, T_EXEC_NAME,
			T_TRADE_PRICE, T_CHRG, T_COMM, T_TAX, T_LIFO)
	VALUES 		(nextval('seq_trade_id'), now_dts, status_id, trade_type_id, 
			is_cash, symbol, trade_qty, requested_price, acct_id, 
			exec_name, NULL, charge_amount, comm_amount, 0, is_lifo);

	-- Get the just generated trade id
	SELECT currval('seq_trade_id')
	INTO trade_id;

	-- Record pending trade information in TRADE_REQUEST table if this trade is a
	-- limit trade
	IF type_is_market THEN
		INSERT INTO TRADE_REQUEST (
					TR_T_ID, TR_TT_ID, TR_S_SYMB,
					TR_QTY, TR_BID_PRICE, TR_CA_ID)
		VALUES 			(trade_id, trade_type_id, symbol,
					trade_qty, requested_price, acct_id);
	END IF;

	-- Record trade information in TRADE_HISTORY table.
	INSERT INTO TRADE_HISTORY (
				TH_T_ID, TH_DTS, TH_ST_ID)
	VALUES (trade_id, now_dts, status_id);

	-- Return trade_id generated by SUT
	RETURN trade_id;

END;
$$ LANGUAGE 'plpgsql';