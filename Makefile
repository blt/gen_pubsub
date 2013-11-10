REBAR=`which rebar`
DIALYZER=`which dialyzer`

all: compile

deps:
	@$(REBAR) get-deps

compile: deps
	@$(REBAR) compile

app.plt:
	@$(DIALYZER) --build_plt --output_plt app.plt --apps erts kernel stdlib crypto

dialyze: app.plt compile
	@$(DIALYZER) --plt app.plt ebin -Wunmatched_returns \
		-Werror_handling -Wrace_conditions -Wno_undefined_callbacks

test: compile
	ct_run -dir test/ -pa src/ -pa ebin/ -verbosity 0 -logdir .ct/logs -cover test/cover.spec -erl_args +K true +A 10

validate: dialyze test

docs: compile
	erl -noshell -run edoc_run application \
	"'$(APP_NAME)'" '"."' '[{def,{vsn,"$(VSN)"}}]'

clean:
	@$(RM) -rf deps/
	@$(REBAR) clean

.PHONY: all test clean validate dialyze deps ct
