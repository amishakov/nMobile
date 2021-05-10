import 'package:flutter/material.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/components/text/label.dart';
import 'package:nmobile/components/wallet/avatar.dart';
import 'package:nmobile/generated/l10n.dart';
import 'package:nmobile/schema/wallet.dart';
import 'package:nmobile/theme/theme.dart';
import 'package:nmobile/utils/format.dart';

class WalletItem extends StatefulWidget {
  final String type;
  final WalletSchema schema;
  final GestureTapCallback onTap;
  final Color bgColor;
  final BorderRadius radius;
  final EdgeInsetsGeometry padding;
  final Widget tail;

  WalletItem({
    this.type,
    this.schema,
    this.onTap,
    this.bgColor,
    this.radius,
    this.padding,
    this.tail,
  });

  @override
  _WalletItemState createState() => _WalletItemState();
}

class _WalletItemState extends State<WalletItem> {
  @override
  Widget build(BuildContext context) {
    return widget.onTap != null
        ? Material(
            color: widget.bgColor,
            elevation: 0,
            borderRadius: widget.radius,
            child: InkWell(
              borderRadius: widget.radius,
              onTap: widget.onTap,
              child: _getItemBody(),
            ),
          )
        : _getItemBody();
  }

  Widget _getItemBody() {
    S _localizations = S.of(context);
    SkinTheme theme = application.theme;

    return Container(
      decoration: BoxDecoration(
        color: widget.bgColor,
        borderRadius: widget.radius,
      ),
      padding: widget.padding ?? EdgeInsets.only(left: 16, right: 16),
      child: Row(
        children: [
          Hero(
            tag: 'avatar:${widget.schema?.address}',
            child: WalletAvatar(
              width: 48,
              height: 48,
              walletType: widget.type,
              padding: EdgeInsets.only(right: 20, top: 16, bottom: 16),
            ),
          ),
          Expanded(
            flex: 1,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Label(
                  widget.schema?.name ?? "",
                  type: LabelType.h3,
                ),
                Label(
                  nknFormat(widget.schema?.balance ?? 0, decimalDigits: 4, symbol: 'NKN'),
                  type: LabelType.bodySmall,
                ),
              ],
            ),
          ),
          SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(9)),
                  color: widget.type == WalletType.eth ? theme.ethLogoBackground.withAlpha(25) : theme.successColor.withAlpha(25),
                ),
                child: Text(
                  widget.type == WalletType.eth ? _localizations.ERC_20 : _localizations.mainnet,
                  style: TextStyle(
                    color: widget.type == WalletType.eth ? theme.ethLogoBackground : theme.successColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                ),
              ),
              widget.type == WalletType.eth
                  ? Padding(
                      padding: EdgeInsets.only(right: 4, top: 4),
                      child: Label(
                        nknFormat(widget.schema?.balanceEth, symbol: 'ETH'),
                        type: LabelType.bodySmall,
                      ),
                    )
                  : SizedBox.shrink(),
            ],
          ),
          widget.tail ?? Container(),
        ],
      ),
    );
  }
}
