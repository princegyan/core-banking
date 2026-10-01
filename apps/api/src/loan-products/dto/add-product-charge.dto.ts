import {
  IsBoolean,
  IsEnum,
  IsOptional,
  IsUUID,
} from 'class-validator';

export enum LoanChargeEvent {
  DISBURSEMENT = 'DISBURSEMENT',
  REPAYMENT = 'REPAYMENT',
  LATE_PAYMENT = 'LATE_PAYMENT',
  PREPAYMENT = 'PREPAYMENT',
  RESTRUCTURE = 'RESTRUCTURE',
  INSURANCE = 'INSURANCE',
  APPLICATION = 'APPLICATION',
}

export class AddProductChargeDto {
  @IsUUID()
  feeId: string;

  @IsEnum(LoanChargeEvent)
  chargeEvent: LoanChargeEvent;

  @IsBoolean()
  @IsOptional()
  isMandatory?: boolean;
}
