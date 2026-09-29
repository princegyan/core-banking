import {
  IsNotEmpty,
  IsUUID,
} from 'class-validator';

export class CreateReversalDto {
  @IsUUID()
  transactionId: string;

  @IsNotEmpty()
  reason: string;
}